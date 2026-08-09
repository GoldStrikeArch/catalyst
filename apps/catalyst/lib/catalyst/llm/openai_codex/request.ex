defmodule Catalyst.LLM.OpenAICodex.Request do
  @moduledoc """
  Builds the Codex Responses request body and its stable semantic projection
  (ported from PI's `buildRequestBody` + `convertResponsesMessages` /
  `convertResponsesTools`).

  The resolved system prompt and a host-owned exact model-identity note go in
  `instructions` (not in `input`). Messages convert to Responses `input` items;
  reasoning blocks are replayed from their stored signature; tool-call ids carry
  `"<call_id>|<item_id>"` and are split apart. The semantic projection reuses the
  same encoder while omitting generated assistant replay ids, so request
  fingerprints never depend on random values, and replacing `input_image` data
  URLs with a digest plus payload size so image-bearing turns are not estimated
  as megabytes of text. The wire body is unaffected: real base64 still ships.
  """

  alias Catalyst.{Content, Message}
  alias Catalyst.Context.Tokens

  @provider_module "Elixir.Catalyst.LLM.OpenAICodex.Provider"
  @default_instructions "You are a helpful assistant."

  @typedoc "Whether generated assistant replay item ids are emitted."
  @type assistant_replay_ids :: :generate | :omit

  @typedoc "Options controlling the conversion of messages into request input items."
  @type input_options :: [assistant_replay_ids: assistant_replay_ids()]

  @doc "Build the JSON-encodable request body map."
  @spec build(Catalyst.Model.t(), Catalyst.LLM.Context.t(), keyword()) :: map()
  def build(model, context, opts \\ []) do
    model
    |> base(context, opts)
    |> Map.put(
      "input",
      input_items(context.messages, model, assistant_replay_ids: :generate)
    )
  end

  @doc """
  Build the stable provider-visible projection used for request accounting.

  Runtime-only transport options and generated assistant replay ids are absent.
  Reasoning and function-call item ids remain because they are sent verbatim to
  the provider. JSON-equivalent tool schemas and function arguments normalize
  to the same value. `input_image` parts carry `"image_digest"` and `"bytes"`
  instead of their data URL — see the module doc — and are marked with
  `Catalyst.Context.Tokens.tag_image_block/1` so only these harness-built
  blocks (never model-written tool arguments) are priced as images.
  """
  @spec semantic_projection(Catalyst.Model.t(), Catalyst.LLM.Context.t(), keyword()) :: map()
  def semantic_projection(model, context, opts \\ []) do
    body = base(model, context, opts)

    %{
      provider: %{module: @provider_module, api: model.api, provider: model.provider},
      model: Map.take(model, [:id, :api, :provider, :base_url]),
      instructions: body["instructions"],
      tools: body |> Map.get("tools", []) |> json_semantic_value(),
      options: semantic_options(body),
      messages:
        context.messages
        |> input_items(model, assistant_replay_ids: :omit)
        |> Enum.map(&semantic_item/1)
    }
  end

  @doc "Build request fields other than `input`, for websocket delta selection."
  @spec base(Catalyst.Model.t(), Catalyst.LLM.Context.t(), keyword()) :: map()
  def base(model, context, opts \\ []) do
    %{
      "model" => model.id,
      "store" => false,
      "stream" => true,
      "instructions" => instructions(context.system_prompt, model.id),
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

  defp instructions(system_prompt, model_id) do
    prompt = system_prompt || @default_instructions
    encoded_id = Jason.encode!(model_id)

    prompt <>
      "\n\nRuntime model identity: this request is using the exact model identifier " <>
      encoded_id <>
      ". If asked which model is in use, report that identifier exactly; " <>
      "do not infer or substitute a different model name."
  end

  @doc """
  Responses `input` items for a message list (what `build/3` puts under
  `"input"`). The websocket delta path uses this to encode ONLY the messages
  the connection's `previous_response_id` doesn't already cover. Pass the
  model so image handling matches what `build/3` would produce.

  Set `:assistant_replay_ids` to `:omit` only when building a stable semantic
  projection. Wire requests use the default `:generate` mode.
  """
  @spec input_items([Catalyst.Message.t()], Catalyst.Model.t() | nil, input_options()) :: [map()]
  def input_items(messages, model \\ nil, opts \\ []) do
    convert_messages(messages, image_input?(model), replay_id_mode(opts))
  end

  # Whether the model accepts image input (nil model → assume yes).
  defp image_input?(nil), do: true
  defp image_input?(model), do: :image in List.wrap(model.input)

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

  defp convert_messages(messages, image_input?, replay_ids),
    do: Enum.flat_map(messages, &convert_message(&1, image_input?, replay_ids))

  defp convert_message(%Message.User{content: content}, image_input?, _replay_ids),
    do: [%{"role" => "user", "content" => user_content(content, image_input?)}]

  defp convert_message(%Message.Assistant{content: blocks}, _image_input?, replay_ids),
    do: Enum.flat_map(blocks, &assistant_block(&1, replay_ids))

  # Tool results with images ship as a function_call_output ITEM LIST
  # (input_text + input_image parts) when the model accepts images — PI's
  # openai-responses-shared behavior; a non-vision model gets the text (or a
  # placeholder note) instead.
  defp convert_message(
         %Message.ToolResult{tool_call_id: id, content: content},
         image_input?,
         _replay_ids
       ) do
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

  defp convert_message(_, _image_input?, _replay_ids), do: []

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

  # Reasoning items are replayed from their stored signature, minus the
  # stream-position bookkeeping the websocket events attach: the backend
  # rejects a replayed `output_index` with a 400 `unknown_parameter`
  # (verified live), so an aborted run's transcript would poison every later
  # full upload. Stripping at replay also repairs already-persisted sessions.
  @non_replayable_reasoning_fields ~w(output_index sequence_number)

  defp assistant_block(%Content.Thinking{signature: sig}, _replay_ids) when is_binary(sig) do
    case Jason.decode(sig) do
      {:ok, %{} = item} -> [Map.drop(item, @non_replayable_reasoning_fields)]
      _ -> []
    end
  end

  defp assistant_block(%Content.Thinking{}, _replay_ids), do: []

  defp assistant_block(%Content.Text{text: text}, replay_ids) do
    item = %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}],
      "status" => "completed"
    }

    [maybe_put_replay_id(item, replay_ids)]
  end

  defp assistant_block(
         %Content.ToolCall{id: id, name: name, arguments: args},
         _replay_ids
       ) do
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

  defp assistant_block(_, _replay_ids), do: []

  defp maybe_put_replay_id(item, :generate), do: Map.put(item, "id", gen_msg_id())
  defp maybe_put_replay_id(item, :omit), do: item

  defp replay_id_mode(opts) do
    case Keyword.get(opts, :assistant_replay_ids, :generate) do
      :omit -> :omit
      _generate_or_invalid -> :generate
    end
  end

  defp semantic_options(body) do
    %{
      text_verbosity: get_in(body, ["text", "verbosity"]),
      prompt_cache_key: Map.get(body, "prompt_cache_key"),
      service_tier: Map.get(body, "service_tier"),
      reasoning: Map.get(body, "reasoning")
    }
  end

  defp semantic_item(%{"type" => "function_call", "arguments" => arguments} = item)
       when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, value} -> Map.put(item, "arguments", value)
      {:error, _reason} -> item
    end
  end

  defp semantic_item(%{"type" => "function_call_output", "output" => parts} = item)
       when is_list(parts),
       do: semantic_parts_item(item, "output", parts)

  defp semantic_item(%{"role" => "user", "content" => parts} = item) when is_list(parts),
    do: semantic_parts_item(item, "content", parts)

  defp semantic_item(item), do: json_semantic_value(item)

  # Image parts are tagged with `Tokens.tag_image_block/1` — an ATOM key — and
  # only AFTER `json_semantic_value/1`, which would stringify it. The parts
  # lists here are built by the harness from `Content` structs, never from
  # model-written data; a model's function-call arguments are decoded JSON
  # (string keys only) and so can never forge the tag, which is what keeps
  # `Tokens.estimate_projection/1` from pricing argument maps merely shaped
  # like image blocks.
  defp semantic_parts_item(item, key, parts) do
    item
    |> Map.put(key, Enum.map(parts, &semantic_part/1))
    |> json_semantic_value()
    |> tag_image_parts(key)
  end

  defp tag_image_parts(%{} = item, key),
    do: Map.update(item, key, [], fn parts -> Enum.map(parts, &tag_image_part/1) end)

  defp tag_image_parts(item, _key), do: item

  defp tag_image_part(%{"type" => "input_image"} = part), do: Tokens.tag_image_block(part)
  defp tag_image_part(part), do: part

  # The wire request keeps the real `data:<mime>;base64,<payload>` URL; only the
  # projection swaps it for a digest plus the payload size. Embedding the base64
  # would make `Tokens.estimate_projection/1` price a screenshot as a megabyte of
  # text; the digest (over the whole URL, so the mime type stays covered) keeps
  # two different images distinguishable for fingerprints and the delta-upload
  # prefix check, and `"bytes"` carries the size the estimator prices.
  defp semantic_part(%{"type" => "input_image", "image_url" => url} = part)
       when is_binary(url) do
    part
    |> Map.delete("image_url")
    |> Map.put("image_digest", image_digest(url))
    |> Map.put("bytes", image_payload_size(url))
  end

  defp semantic_part(part), do: part

  defp image_digest(url),
    do: url |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp image_payload_size(url) do
    case String.split(url, ";base64,", parts: 2) do
      [_prefix, payload] -> byte_size(payload)
      [_not_a_data_url] -> byte_size(url)
    end
  end

  defp json_semantic_value(value) do
    with {:ok, encoded} <- Jason.encode(value),
         {:ok, decoded} <- Jason.decode(encoded) do
      decoded
    else
      _not_json -> value
    end
  end

  defp split_id(id) do
    case String.split(id, "|", parts: 2) do
      [call_id, item_id] -> {call_id, item_id}
      [call_id] -> {call_id, call_id}
    end
  end

  defp gen_msg_id, do: "msg_" <> Catalyst.Ids.hex(12)
end
