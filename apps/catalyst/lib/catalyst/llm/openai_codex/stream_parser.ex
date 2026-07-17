defmodule Catalyst.LLM.OpenAICodex.StreamParser do
  @moduledoc """
  Folds OpenAI Responses API SSE events into a `Catalyst.Message.Assistant`
  (ported from PI's `processResponsesStream`).

  Reasoning items are captured whole into the thinking block's `signature` so
  they can be replayed verbatim on the next request (required for Codex tool-call
  continuity alongside `include: ["reasoning.encrypted_content"]`). Tool-call ids
  are stored as `"<call_id>|<item_id>"`.
  """

  alias Catalyst.{Content, Message, Usage}
  alias Catalyst.LLM.Event

  defstruct blocks: [],
            current: nil,
            response_id: nil,
            usage: %Usage{},
            stop_reason: :stop,
            error: nil

  def new, do: %__MODULE__{}

  @doc "Apply one decoded SSE event, emitting normalized events to `sink`."
  def handle(%__MODULE__{} = s, %{"type" => type} = ev, sink), do: do_handle(type, ev, s, sink)
  def handle(s, _ev, _sink), do: s

  # ---- item lifecycle -------------------------------------------------------

  defp do_handle("response.created", ev, s, _sink),
    do: %{s | response_id: get_in(ev, ["response", "id"]) || s.response_id}

  defp do_handle("response.output_item.added", %{"item" => item}, s, sink) do
    case item["type"] do
      "reasoning" ->
        %{s | current: {:reasoning, %{thinking: "", item: item}}}

      "message" ->
        sink.(%Event.TextStart{})
        %{s | current: {:text, %{text: "", id: item["id"]}}}

      "function_call" ->
        id = "#{item["call_id"]}|#{item["id"]}"
        sink.(%Event.ToolCallStart{id: id, name: item["name"]})
        %{s | current: {:tool, %{id: id, name: item["name"], partial: item["arguments"] || ""}}}

      _ ->
        s
    end
  end

  # ---- deltas ---------------------------------------------------------------

  defp do_handle(reason_delta, ev, s, sink)
       when reason_delta in ["response.reasoning_text.delta", "response.reasoning_summary_text.delta"] do
    case s.current do
      {:reasoning, r} ->
        delta = ev["delta"] || ""
        sink.(%Event.ThinkingDelta{delta: delta})
        %{s | current: {:reasoning, %{r | thinking: r.thinking <> delta}}}

      _ ->
        s
    end
  end

  defp do_handle("response.output_text.delta", ev, s, sink) do
    case s.current do
      {:text, t} ->
        delta = ev["delta"] || ""
        sink.(%Event.TextDelta{delta: delta})
        %{s | current: {:text, %{t | text: t.text <> delta}}}

      _ ->
        s
    end
  end

  defp do_handle("response.function_call_arguments.delta", ev, s, sink) do
    case s.current do
      {:tool, t} ->
        delta = ev["delta"] || ""
        sink.(%Event.ToolCallDelta{id: t.id, delta: delta})
        %{s | current: {:tool, %{t | partial: t.partial <> delta}}}

      _ ->
        s
    end
  end

  defp do_handle("response.function_call_arguments.done", ev, s, _sink) do
    case s.current do
      {:tool, t} -> %{s | current: {:tool, %{t | partial: ev["arguments"] || t.partial}}}
      _ -> s
    end
  end

  # ---- item done ------------------------------------------------------------

  defp do_handle("response.output_item.done", %{"item" => item}, s, sink) do
    case item["type"] do
      "reasoning" ->
        text = reasoning_text(item, s)
        block = %Content.Thinking{thinking: text, signature: Jason.encode!(item)}
        %{s | blocks: [block | s.blocks], current: nil}

      "message" ->
        text = current_text(s) |> default(message_text(item))
        sink.(%Event.TextEnd{})
        %{s | blocks: [%Content.Text{text: text} | s.blocks], current: nil}

      "function_call" ->
        {id, name, partial} = current_tool(s, item)
        args = decode_args(partial, item["arguments"])
        sink.(%Event.ToolCallEnd{id: id, name: name, arguments: args})
        %{s | blocks: [%Content.ToolCall{id: id, name: name, arguments: args} | s.blocks], current: nil}

      _ ->
        s
    end
  end

  # ---- completion / errors --------------------------------------------------

  defp do_handle("response.completed", %{"response" => resp}, s, _sink) do
    usage = usage_from(resp["usage"])
    stop = stop_reason(resp["status"])
    blocks = s.blocks
    stop = if stop == :stop and Enum.any?(blocks, &match?(%Content.ToolCall{}, &1)), do: :tool_use, else: stop
    %{s | usage: usage, stop_reason: stop, response_id: resp["id"] || s.response_id}
  end

  defp do_handle("error", ev, s, _sink),
    do: %{s | error: "Error #{ev["code"]}: #{ev["message"]}", stop_reason: :error}

  defp do_handle("response.failed", %{"response" => resp}, s, _sink) do
    err = resp["error"]
    msg = if err, do: "#{err["code"] || "unknown"}: #{err["message"]}", else: "response failed"
    %{s | error: msg, stop_reason: :error}
  end

  defp do_handle(_type, _ev, s, _sink), do: s

  @doc "Build the final assistant message."
  def finalize(%__MODULE__{} = s, model) do
    content =
      if s.error,
        do: Enum.reverse([%Content.Text{text: s.error} | s.blocks]),
        else: Enum.reverse(s.blocks)

    %Message.Assistant{
      content: content,
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: s.usage,
      stop_reason: s.stop_reason,
      error_message: s.error,
      response_id: s.response_id,
      timestamp: Message.now()
    }
  end

  # ---- helpers --------------------------------------------------------------

  defp current_text(%{current: {:text, t}}), do: t.text
  defp current_text(_), do: nil

  defp current_tool(%{current: {:tool, t}}, _item), do: {t.id, t.name, t.partial}
  defp current_tool(_, item), do: {"#{item["call_id"]}|#{item["id"]}", item["name"], item["arguments"] || "{}"}

  defp default(nil, fallback), do: fallback
  defp default("", fallback), do: fallback
  defp default(value, _fallback), do: value

  defp message_text(item) do
    (item["content"] || [])
    |> Enum.map_join("", fn part -> part["text"] || part["refusal"] || "" end)
  end

  defp reasoning_text(item, s) do
    summary = (item["summary"] || []) |> Enum.map_join("\n\n", &(&1["text"] || ""))
    content = (item["content"] || []) |> Enum.map_join("\n\n", &(&1["text"] || ""))

    cond do
      summary != "" -> summary
      content != "" -> content
      true -> reasoning_partial(s)
    end
  end

  defp reasoning_partial(%{current: {:reasoning, r}}), do: r.thinking
  defp reasoning_partial(_), do: ""

  defp decode_args(partial, fallback) do
    json = if is_binary(partial) and partial != "", do: partial, else: fallback || "{}"

    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp usage_from(nil), do: %Usage{}

  defp usage_from(u) do
    cached = get_in(u, ["input_tokens_details", "cached_tokens"]) || 0
    input = (u["input_tokens"] || 0) - cached

    %Usage{
      input: input,
      output: u["output_tokens"] || 0,
      cache_read: cached,
      total_tokens: u["total_tokens"] || 0
    }
  end

  defp stop_reason("completed"), do: :stop
  defp stop_reason("incomplete"), do: :length
  defp stop_reason("failed"), do: :error
  defp stop_reason("cancelled"), do: :error
  defp stop_reason(_), do: :stop
end
