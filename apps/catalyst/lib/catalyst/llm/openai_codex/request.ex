defmodule Catalyst.LLM.OpenAICodex.Request do
  @moduledoc """
  Builds the Codex Responses request body (ported from PI's `buildRequestBody` +
  `convertResponsesMessages` / `convertResponsesTools`).

  The system prompt goes in `instructions` (not in `input`). Messages convert to
  Responses `input` items; reasoning blocks are replayed from their stored
  signature; tool-call ids carry `"<call_id>|<item_id>"` and are split apart.
  """

  alias Catalyst.{Content, Message}

  @doc "Build the JSON-encodable request body map."
  @spec build(Catalyst.Model.t(), Catalyst.LLM.Context.t(), keyword()) :: map()
  def build(model, context, opts \\ []) do
    body = %{
      "model" => model.id,
      "store" => false,
      "stream" => true,
      "instructions" => context.system_prompt || "You are a helpful assistant.",
      "input" => convert_messages(context.messages),
      "text" => %{"verbosity" => Keyword.get(opts, :text_verbosity, "low")},
      "include" => ["reasoning.encrypted_content"],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true
    }

    body
    |> maybe_put("prompt_cache_key", opts[:session_id])
    # "Fast mode": service_tier "priority" (the only tier the Codex backend
    # exposes; ~1.5x speed, increased usage). Omitted entirely otherwise.
    |> maybe_put("service_tier", opts[:service_tier])
    |> maybe_put_tools(context.tools)
    |> maybe_put_reasoning(opts[:reasoning_effort], opts[:reasoning_summary])
  end

  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp maybe_put_tools(body, tools) when is_list(tools) and tools != [],
    do: Map.put(body, "tools", convert_tools(tools))

  defp maybe_put_tools(body, _), do: body

  defp maybe_put_reasoning(body, nil, _summary), do: body

  defp maybe_put_reasoning(body, effort, summary),
    do: Map.put(body, "reasoning", %{"effort" => effort, "summary" => summary || "auto"})

  # ---- tools ----------------------------------------------------------------

  defp convert_tools(tools) do
    Enum.map(tools, fn t ->
      %{
        "type" => "function",
        "name" => t.name,
        "description" => t.description,
        "parameters" => t.parameters,
        "strict" => nil
      }
    end)
  end

  # ---- messages -> Responses input items ------------------------------------

  defp convert_messages(messages), do: Enum.flat_map(messages, &convert_message/1)

  defp convert_message(%Message.User{content: content}),
    do: [%{"role" => "user", "content" => user_content(content)}]

  defp convert_message(%Message.Assistant{content: blocks}),
    do: Enum.flat_map(blocks, &assistant_block/1)

  defp convert_message(%Message.ToolResult{tool_call_id: id, content: content}) do
    {call_id, _item} = split_id(id)

    [
      %{
        "type" => "function_call_output",
        "call_id" => call_id,
        "output" => Content.text_of(content)
      }
    ]
  end

  defp convert_message(_), do: []

  defp user_content(content) do
    Enum.map(content, fn
      %Content.Text{text: t} ->
        %{"type" => "input_text", "text" => t}

      %Content.Image{data: d, mime_type: mt} ->
        %{"type" => "input_image", "detail" => "auto", "image_url" => "data:#{mt};base64,#{d}"}
    end)
  end

  # Reasoning items are replayed verbatim from their stored signature.
  defp assistant_block(%Content.Thinking{signature: sig}) when is_binary(sig) do
    case Jason.decode(sig) do
      {:ok, item} -> [item]
      _ -> []
    end
  end

  defp assistant_block(%Content.Thinking{}), do: []

  defp assistant_block(%Content.Text{text: text}) do
    [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}],
        "status" => "completed",
        "id" => gen_msg_id()
      }
    ]
  end

  defp assistant_block(%Content.ToolCall{id: id, name: name, arguments: args}) do
    {call_id, item_id} = split_id(id)

    [
      %{
        "type" => "function_call",
        "id" => item_id,
        "call_id" => call_id,
        "name" => name,
        "arguments" => Jason.encode!(args)
      }
    ]
  end

  defp assistant_block(_), do: []

  defp split_id(id) do
    case String.split(id, "|", parts: 2) do
      [call_id, item_id] -> {call_id, item_id}
      [call_id] -> {call_id, call_id}
    end
  end

  defp gen_msg_id, do: "msg_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
end
