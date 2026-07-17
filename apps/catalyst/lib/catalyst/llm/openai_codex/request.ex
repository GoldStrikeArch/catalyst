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
    model
    |> base(context, opts)
    |> Map.put("input", convert_messages(context.messages, image_input?(model)))
  end

  @doc "Build request fields other than `input`, for websocket delta selection."
  @spec base(Catalyst.Model.t(), Catalyst.LLM.Context.t(), keyword()) :: map()
  def base(model, context, opts \\ []) do
    %{
      "model" => model.id,
      "store" => false,
      "stream" => true,
      "instructions" => context.system_prompt || "You are a helpful assistant.",
      "text" => %{"verbosity" => Keyword.get(opts, :text_verbosity, "low")},
      "include" => ["reasoning.encrypted_content"],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true
    }
    |> maybe_put("prompt_cache_key", opts[:session_id])
    # "Fast mode": service_tier "priority" (the only tier the Codex backend
    # exposes; ~1.5x speed, increased usage). Omitted entirely otherwise.
    |> maybe_put("service_tier", opts[:service_tier])
    |> maybe_put_tools(context.tools)
    |> maybe_put_reasoning(opts[:reasoning_effort], opts[:reasoning_summary])
  end

  @doc """
  Responses `input` items for a message list (what `build/3` puts under
  `"input"`). The websocket delta path uses this to encode ONLY the messages
  the connection's `previous_response_id` doesn't already cover. Pass the
  model so image handling matches what `build/3` would produce.
  """
  @spec input_items([Catalyst.Message.t()], Catalyst.Model.t() | nil) :: [map()]
  def input_items(messages, model \\ nil), do: convert_messages(messages, image_input?(model))

  @doc "Whether the model accepts image input (nil model → assume yes)."
  @spec image_input?(Catalyst.Model.t() | nil) :: boolean()
  def image_input?(nil), do: true
  def image_input?(model), do: :image in List.wrap(model.input)

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

  defp convert_messages(messages, image_input?),
    do: Enum.flat_map(messages, &convert_message(&1, image_input?))

  defp convert_message(%Message.User{content: content}, image_input?),
    do: [%{"role" => "user", "content" => user_content(content, image_input?)}]

  defp convert_message(%Message.Assistant{content: blocks}, _image_input?),
    do: Enum.flat_map(blocks, &assistant_block/1)

  # Tool results with images ship as a function_call_output ITEM LIST
  # (input_text + input_image parts) when the model accepts images — PI's
  # openai-responses-shared behavior; a non-vision model gets the text (or a
  # placeholder note) instead.
  defp convert_message(%Message.ToolResult{tool_call_id: id, content: content}, image_input?) do
    {call_id, _item} = split_id(id)
    images = Enum.filter(content, &match?(%Content.Image{}, &1))
    text = Content.text_of(content)

    output =
      cond do
        images != [] and image_input? ->
          text_parts = if text == "", do: [], else: [%{"type" => "input_text", "text" => text}]

          text_parts ++
            Enum.map(images, fn %Content.Image{data: d, mime_type: mt} ->
              %{
                "type" => "input_image",
                "detail" => "auto",
                "image_url" => "data:#{mt};base64,#{d}"
              }
            end)

        images != [] and text == "" ->
          "(see attached image)"

        true ->
          text
      end

    [%{"type" => "function_call_output", "call_id" => call_id, "output" => output}]
  end

  defp convert_message(_, _image_input?), do: []

  defp user_content(content, image_input?) do
    parts =
      Enum.flat_map(content, fn
        %Content.Text{text: text} ->
          [%{"type" => "input_text", "text" => text}]

        %Content.Image{data: data, mime_type: mime_type} when image_input? ->
          [
            %{
              "type" => "input_image",
              "detail" => "auto",
              "image_url" => "data:#{mime_type};base64,#{data}"
            }
          ]

        %Content.Image{} ->
          []

        # Unknown block types (e.g. from extensions) are dropped, mirroring
        # assistant_block/1 — the request must never crash the run task.
        _other ->
          []
      end)

    case {parts, Enum.any?(content, &match?(%Content.Image{}, &1))} do
      {[], true} -> [%{"type" => "input_text", "text" => "(see attached image)"}]
      _ -> parts
    end
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

  defp gen_msg_id, do: "msg_" <> Catalyst.Ids.hex(12)
end
