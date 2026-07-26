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
  alias Catalyst.LLM.OpenAICodex.ResponseEvent

  defstruct blocks: [],
            current: nil,
            items: %{},
            next_item_seq: 0,
            response_id: nil,
            usage: %Usage{},
            stop_reason: :stop,
            error: nil,
            # Set by a terminal event (completed/incomplete/failed/cancelled/error);
            # finalize/2 marks the turn as errored when the stream ends without one.
            done: false

  @type t :: %__MODULE__{
          blocks: [Content.t()],
          current: term() | nil,
          items: %{optional(term()) => map()},
          next_item_seq: non_neg_integer(),
          response_id: String.t() | nil,
          usage: Usage.t(),
          stop_reason: Message.Assistant.stop_reason(),
          error: String.t() | nil,
          done: boolean()
        }

  @doc "A fresh parser state for one streamed response."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Apply one decoded SSE event, emitting normalized events to `sink`."
  @spec handle(t(), map(), Catalyst.LLM.Provider.sink()) :: t()
  def handle(%__MODULE__{} = s, %{"type" => _type} = event, sink) do
    event = ResponseEvent.normalize(event)
    do_handle(event["type"], event, s, sink)
  end

  def handle(s, _ev, _sink), do: s

  # ---- item lifecycle -------------------------------------------------------

  defp do_handle("response.created", ev, s, _sink),
    do: %{s | response_id: get_in(ev, ["response", "id"]) || s.response_id}

  defp do_handle("response.output_item.added", %{"item" => item} = event, s, sink) do
    item = Map.put_new(item, "output_index", event["output_index"])

    case item["type"] do
      "reasoning" ->
        put_item(s, item, :reasoning, %{thinking: []})

      "message" ->
        sink.(%Event.TextStart{})
        put_item(s, item, :text, %{text: []})

      "function_call" ->
        id = "#{item["call_id"]}|#{item["id"]}"
        sink.(%Event.ToolCallStart{id: id, name: item["name"]})

        put_item(s, item, :tool, %{
          id: id,
          name: item["name"],
          partial: chunks(item["arguments"] || "")
        })

      _ ->
        s
    end
  end

  # ---- deltas ---------------------------------------------------------------

  defp do_handle(reason_delta, ev, s, sink)
       when reason_delta in [
              "response.reasoning_text.delta",
              "response.reasoning_summary_text.delta"
            ] do
    case s.current do
      key when not is_nil(key) ->
        delta = ev["delta"] || ""

        update_item(s, ev, key, :reasoning, fn item ->
          sink.(%Event.ThinkingDelta{delta: delta})
          %{item | thinking: add_chunk(item.thinking, delta)}
        end)

      nil ->
        update_item(s, ev, nil, :reasoning, fn item ->
          delta = ev["delta"] || ""
          sink.(%Event.ThinkingDelta{delta: delta})
          %{item | thinking: add_chunk(item.thinking, delta)}
        end)
    end
  end

  defp do_handle("response.output_text.delta", ev, s, sink) do
    delta = ev["delta"] || ""

    update_item(s, ev, s.current, :text, fn item ->
      sink.(%Event.TextDelta{delta: delta})
      %{item | text: add_chunk(item.text, delta)}
    end)
  end

  defp do_handle("response.function_call_arguments.delta", ev, s, sink) do
    delta = ev["delta"] || ""

    update_item(s, ev, s.current, :tool, fn item ->
      sink.(%Event.ToolCallDelta{id: item.id, delta: delta})
      %{item | partial: add_chunk(item.partial, delta)}
    end)
  end

  defp do_handle("response.function_call_arguments.done", ev, s, _sink) do
    update_item(s, ev, s.current, :tool, fn item ->
      %{item | partial: replace_chunks(item.partial, ev["arguments"])}
    end)
  end

  # ---- item done ------------------------------------------------------------

  defp do_handle("response.output_item.done", %{"item" => item} = event, s, sink) do
    item = Map.put_new(item, "output_index", event["output_index"])

    case item["type"] do
      "reasoning" ->
        text = reasoning_text(item, s)
        block = %Content.Thinking{thinking: text, signature: Jason.encode!(item)}
        complete_item(s, item, block)

      "message" ->
        # The done item carries the COMPLETE text — authoritative over the
        # accumulated deltas (a dropped delta frame would otherwise silently
        # truncate the message).
        text = message_text(item) |> default(current_text(s, item) || "")
        sink.(%Event.TextEnd{})
        complete_item(s, item, %Content.Text{text: text})

      "function_call" ->
        {id, name, partial} = current_tool(s, item)
        # Same authority rule: the done item's full `arguments` string beats
        # the accumulated deltas (dropped frame ⇒ corrupt/empty args).
        case decode_args(item["arguments"], partial) do
          {:ok, args} ->
            sink.(%Event.ToolCallEnd{id: id, name: name, arguments: args})
            complete_item(s, item, %Content.ToolCall{id: id, name: name, arguments: args})

          {:error, reason} ->
            invalidate_item(s, item, "invalid tool arguments for #{name}: #{reason}")
        end

      _ ->
        s
    end
  end

  # ---- completion / errors --------------------------------------------------

  defp do_handle("response.completed", %{"response" => resp}, s, _sink) do
    usage = usage_from(resp["usage"])
    stop = stop_reason(resp["status"])
    blocks = output_blocks(s)

    stop =
      cond do
        # A prior "error" event wins — don't let a late completed mask it.
        s.error -> :error
        stop == :stop and Enum.any?(blocks, &match?(%Content.ToolCall{}, &1)) -> :tool_use
        true -> stop
      end

    %{s | usage: usage, stop_reason: stop, response_id: resp["id"] || s.response_id, done: true}
  end

  # Terminal event for a truncated response (e.g. max output tokens hit).
  defp do_handle("response.incomplete", %{"response" => resp}, s, _sink) do
    reason = get_in(resp, ["incomplete_details", "reason"]) || "incomplete"

    %{
      s
      | usage: usage_from(resp["usage"]),
        stop_reason: :length,
        error: s.error || "response incomplete: #{reason}",
        response_id: resp["id"] || s.response_id,
        done: true
    }
  end

  defp do_handle("response.cancelled", %{"response" => resp}, s, _sink) do
    %{
      s
      | usage: usage_from(resp["usage"]),
        stop_reason: :aborted,
        response_id: resp["id"] || s.response_id,
        done: true
    }
  end

  defp do_handle("error", ev, s, _sink),
    do: %{s | error: error_event_message(ev), stop_reason: :error, done: true}

  defp do_handle("response.failed", %{"response" => resp}, s, _sink) do
    msg =
      case resp["error"] do
        %{} = error ->
          "#{present(error["code"]) || present(error["type"]) || "unknown"}: " <>
            (present(error["message"]) || Jason.encode!(error))

        _ ->
          "response failed"
      end

    %{s | error: msg, stop_reason: :error, done: true}
  end

  defp do_handle(_type, _ev, s, _sink), do: s

  # SSE puts code/message at the top level; the websocket frame nests them
  # under "error" (plus an HTTP "status"). Never produce a blank message —
  # an unrecognized shape falls back to the raw event.
  defp error_event_message(ev) do
    nested = ev["error"] || %{}
    code = present(ev["code"]) || present(nested["code"]) || present(nested["type"])
    message = present(ev["message"]) || present(nested["message"])

    case {code, message} do
      {nil, nil} -> "Error: #{ev |> Jason.encode!() |> String.slice(0, 600)}"
      {code, nil} -> "Error #{code}#{status_suffix(ev)}"
      {nil, message} -> "Error#{status_suffix(ev)}: #{message}"
      {code, message} -> "Error #{code}#{status_suffix(ev)}: #{message}"
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp status_suffix(%{"status" => status}) when is_integer(status), do: " (HTTP #{status})"
  defp status_suffix(_ev), do: ""

  @doc "Build the final assistant message."
  @spec finalize(t(), Catalyst.Model.t()) :: Message.Assistant.t()
  def finalize(%__MODULE__{} = s, model) do
    s = s |> flush_current() |> mark_truncated()
    blocks = output_blocks(s)

    content =
      case s.error do
        nil -> blocks
        error -> blocks ++ [%Content.Text{text: error}]
      end

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

  # Keep every partially-streamed text/reasoning item the UI already rendered.
  # Partial tool calls are dropped instead: the loop executes any ToolCall block
  # it sees, and half-received arguments must never run.
  defp flush_current(s) do
    s.items
    |> Enum.sort_by(fn {_key, item} -> {item.output_index, item.seq} end)
    |> Enum.reduce(%{s | current: nil}, fn
      {key, %{status: :open, kind: :text} = item}, acc ->
        put_completed(acc, key, %Content.Text{text: chunks_to_binary(item.text)})

      {key, %{status: :open, kind: :reasoning} = item}, acc ->
        # A partial reasoning item has no encrypted_content; replaying a made-up
        # signature risks a 400, so keep only its visible text.
        block = %Content.Thinking{thinking: chunks_to_binary(item.thinking), signature: nil}
        put_completed(acc, key, block)

      {key, %{status: :open, kind: :tool} = item}, acc ->
        err = "stream ended mid tool call (#{item.name}); the call was discarded"
        stop_reason = preserve_terminal_reason(acc.stop_reason)

        acc = put_invalid(acc, key)
        %{acc | error: acc.error || err, stop_reason: stop_reason}

      _item, acc ->
        acc
    end)
  end

  # No terminal event seen (connection dropped mid-stream): the turn must not
  # look like a clean :stop.
  defp mark_truncated(%{done: false, error: nil} = s),
    do: %{s | stop_reason: :error, error: "response stream ended before completion"}

  defp mark_truncated(s), do: s

  # ---- helpers --------------------------------------------------------------

  defp put_item(s, wire_item, kind, data) do
    key = item_key(wire_item, s.next_item_seq)

    item =
      data
      |> Map.merge(%{
        kind: kind,
        status: :open,
        wire_id: wire_item["id"],
        output_index: wire_item["output_index"] || s.next_item_seq,
        seq: s.next_item_seq
      })

    %{
      s
      | current: key,
        items: Map.put(s.items, key, item),
        next_item_seq: s.next_item_seq + 1
    }
  end

  defp update_item(s, event, fallback_key, kind, fun) do
    case locate_item(s, event, fallback_key, kind) do
      {:ok, key, item} -> %{s | items: Map.put(s.items, key, fun.(item))}
      :error -> s
    end
  end

  defp locate_item(s, event, fallback_key, kind) do
    key = event_item_key(s, event) || fallback_key

    case Map.fetch(s.items, key) do
      {:ok, %{kind: ^kind} = item} -> {:ok, key, item}
      _ -> :error
    end
  end

  defp event_item_key(s, event) do
    id = event["item_id"] || get_in(event, ["item", "id"])
    output_index = event["output_index"] || get_in(event, ["item", "output_index"])

    cond do
      is_binary(id) and Map.has_key?(s.items, {:id, id}) -> {:id, id}
      is_integer(output_index) -> find_by_output_index(s, output_index)
      true -> nil
    end
  end

  defp find_by_output_index(s, output_index) do
    Enum.find_value(s.items, fn {key, item} ->
      case item.output_index == output_index do
        true -> key
        false -> nil
      end
    end)
  end

  defp item_key(%{"id" => id}, _seq) when is_binary(id), do: {:id, id}
  defp item_key(%{"output_index" => index}, _seq) when is_integer(index), do: {:index, index}
  defp item_key(_item, seq), do: {:seq, seq}

  defp complete_item(s, wire_item, block) do
    case event_item_key(s, %{"item" => wire_item}) || s.current do
      nil ->
        %{s | blocks: [block | s.blocks]}

      key ->
        s
        |> put_completed(key, block)
        |> clear_current(key)
    end
  end

  defp invalidate_item(s, wire_item, reason) do
    key = event_item_key(s, %{"item" => wire_item}) || s.current

    s =
      case key do
        nil -> s
        key -> s |> put_invalid(key) |> clear_current(key)
      end

    %{s | error: s.error || reason, stop_reason: :error}
  end

  defp put_completed(s, key, block) do
    update_in(s.items[key], fn
      nil -> nil
      item -> Map.merge(item, %{status: :done, block: block})
    end)
  end

  defp put_invalid(s, key) do
    update_in(s.items[key], fn
      nil -> nil
      item -> Map.put(item, :status, :invalid)
    end)
  end

  defp clear_current(%{current: key} = s, key), do: %{s | current: nil}
  defp clear_current(s, _key), do: s

  defp output_blocks(s) do
    item_blocks =
      s.items
      |> Map.values()
      |> Enum.filter(&match?(%{status: :done, block: _}, &1))
      |> Enum.sort_by(&{&1.output_index, &1.seq})
      |> Enum.map(& &1.block)

    Enum.reverse(s.blocks) ++ item_blocks
  end

  defp current_text(s, item) do
    case locate_item(s, %{"item" => item}, s.current, :text) do
      {:ok, _key, text_item} -> chunks_to_binary(text_item.text)
      :error -> nil
    end
  end

  defp current_tool(s, item) do
    case locate_item(s, %{"item" => item}, s.current, :tool) do
      {:ok, _key, tool} -> {tool.id, tool.name, chunks_to_binary(tool.partial)}
      :error -> {"#{item["call_id"]}|#{item["id"]}", item["name"], item["arguments"] || "{}"}
    end
  end

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
      true -> reasoning_partial(s, item)
    end
  end

  defp reasoning_partial(s, item) do
    case locate_item(s, %{"item" => item}, s.current, :reasoning) do
      {:ok, _key, reasoning} -> chunks_to_binary(reasoning.thinking)
      :error -> ""
    end
  end

  defp chunks(""), do: []
  defp chunks(binary) when is_binary(binary), do: [binary]

  defp add_chunk(chunks, ""), do: chunks
  defp add_chunk(chunks, delta) when is_binary(delta), do: [delta | chunks]

  defp replace_chunks(current, nil), do: current
  defp replace_chunks(_current, binary) when is_binary(binary), do: chunks(binary)
  defp replace_chunks(current, _other), do: current

  defp chunks_to_binary(chunks) when is_list(chunks) do
    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp decode_args(partial, fallback) do
    json =
      case is_binary(partial) and partial != "" do
        true -> partial
        false -> fallback || "{}"
      end

    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, other} -> {:error, "expected a JSON object, got #{inspect(other)}"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp preserve_terminal_reason(reason) when reason in [:aborted, :length], do: reason
  defp preserve_terminal_reason(_reason), do: :error

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
  defp stop_reason("cancelled"), do: :aborted
  defp stop_reason(_), do: :stop
end
