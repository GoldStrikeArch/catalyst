defmodule Catalyst.Context.Tokens do
  @moduledoc """
  Deterministic, provider-neutral request accounting.

  Catalyst hashes one stable semantic projection and estimates conservatively
  at roughly four bytes per token, with separate size-based image pricing. This
  is deliberately coarse rather than tokenizer-specific: the context guard
  applies a conservative window threshold and re-estimates after compaction.
  """

  alias Catalyst.{Content, Message, Model}
  alias Catalyst.LLM.Context, as: LLMContext

  @bytes_per_token 4
  @image_token_floor 1_024

  # Images are projected as `digest + bytes`, never as their base64 payload, so
  # their cost is priced from the recorded byte size instead of being counted as
  # text at `@bytes_per_token`.  Calibrated so ~1 MB of base64 lands near 1,750
  # tokens (Anthropic's measured per-screenshot cost) and larger unresized
  # images over-count conservatively — over-counting is the context guard's safe
  # direction, under-counting is not.
  @image_bytes_per_token 600

  # Harness-built image projections carry this ATOM key (`tag_image_block/1`).
  # Model-written tool-call arguments are decoded JSON and can therefore only
  # ever contain string keys, so the tag is unforgeable by the model: a map in
  # `arguments` merely shaped like an image block is counted as text, never
  # priced as an image (which would let the model steer the context guard).
  @image_tag :__catalyst_image__

  @type fingerprint_source :: :coarse

  @type estimate :: %{
          tokens: non_neg_integer(),
          context_digest: String.t(),
          source: :coarse
        }

  @doc "Estimate one complete request from the canonical semantic projection."
  @spec estimate(Model.t() | nil, LLMContext.t(), keyword() | map()) ::
          {:ok, estimate()} | {:error, term()}
  def estimate(model, %LLMContext{} = context, opts \\ []) do
    projection = provider_projection(model, context, opts)

    {:ok,
     %{
       tokens: estimate_projection(projection),
       context_digest: projection_digest(projection),
       source: :coarse
     }}
  end

  @doc "Coarse token count for one exact LLM context."
  @spec estimate_tokens(Model.t() | nil, LLMContext.t(), keyword() | map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def estimate_tokens(model, %LLMContext{} = context, opts \\ []) do
    {:ok, estimate_projection(provider_projection(model, context, opts))}
  end

  @doc "SHA-256 fingerprint of the canonical request semantics."
  @spec context_fingerprint(Model.t() | nil, LLMContext.t(), keyword() | map()) ::
          {:ok, String.t()} | {:error, term()}
  def context_fingerprint(model, %LLMContext{} = context, opts \\ []) do
    {:ok, semantic_digest(model, context, opts)}
  end

  @doc "Return the canonical request fingerprint and its coarse source."
  @spec context_fingerprint_with_source(Model.t() | nil, LLMContext.t(), keyword() | map()) ::
          {:ok, String.t(), fingerprint_source()} | {:error, term()}
  def context_fingerprint_with_source(model, %LLMContext{} = context, opts \\ []) do
    {:ok, semantic_digest(model, context, opts), :coarse}
  end

  @doc "Stable lowercase SHA-256 hex digest of the provider-semantic projection."
  @spec semantic_digest(Model.t() | nil, LLMContext.t(), keyword() | map()) :: String.t()
  def semantic_digest(model, %LLMContext{} = context, opts \\ []) do
    model
    |> provider_projection(context, opts)
    |> projection_digest()
  end

  @doc """
  Canonical provider-visible semantic fields.  Usage, cost, timestamps,
  assistant response ids, and generated replay message ids are intentionally
  absent; content and tool-call/item ids remain covered.
  """
  @spec provider_projection(Model.t() | nil, LLMContext.t(), keyword() | map()) :: map()
  def provider_projection(model, %LLMContext{} = context, opts \\ []) do
    %{
      provider: provider_identity(model, opts),
      model: model_projection(model),
      instructions: context.system_prompt,
      tools: Enum.map(context.tools || [], &tool_projection/1),
      options: provider_options(opts),
      messages: Enum.map(context.messages || [], &message_projection/1)
    }
  end

  @doc """
  Token estimate for a projection, used by provider adapters without recursion.

  Image blocks carry no payload in a projection — only a digest and a byte
  count — so each is priced at `max(#{@image_token_floor}, bytes /
  #{@image_bytes_per_token})` on top of the canonical binary rather than being
  counted as text within it. A block with no recorded size falls back to the
  floor. Only blocks tagged by `tag_image_block/1` are priced this way —
  model-controlled data (tool-call arguments) can never carry the atom tag,
  so it is always counted as plain text.
  """
  @spec estimate_projection(term()) :: non_neg_integer()
  def estimate_projection(projection) do
    bytes = projection |> canonical_binary() |> byte_size()
    div(bytes + @bytes_per_token - 1, @bytes_per_token) + image_tokens(projection)
  end

  @doc "Return a stable lowercase SHA-256 digest for an already-built semantic projection."
  @spec projection_digest(term()) :: String.t()
  def projection_digest(projection) do
    projection
    |> canonical_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  @spec canonical_binary(term()) :: binary()
  def canonical_binary(term), do: :erlang.term_to_binary(canonical(term), [:deterministic])

  @doc """
  Mark a projection block as a harness-built image block so
  `estimate_projection/1` prices it from its recorded byte size.

  The mark is an atom key. Model-written tool-call arguments are decoded
  JSON — string keys only — so nothing the model produces can carry it;
  projection sites must apply it only to blocks the harness itself built
  (and, when the projection is JSON-normalized, only **after** that
  normalization, which would stringify the atom).
  """
  @spec tag_image_block(map()) :: map()
  def tag_image_block(block) when is_map(block), do: Map.put(block, @image_tag, true)

  defp provider_identity(model, opts) do
    provider = option(opts, :provider)

    %{
      module: if(is_atom(provider), do: Atom.to_string(provider), else: provider),
      api: model && Map.get(model, :api),
      provider: model && Map.get(model, :provider)
    }
  end

  defp model_projection(nil), do: nil

  defp model_projection(model) do
    Map.take(model, [:id, :api, :provider, :base_url])
  end

  defp tool_projection(tool) when is_map(tool) do
    %{
      name: Map.get(tool, :name) || Map.get(tool, "name"),
      description: Map.get(tool, :description) || Map.get(tool, "description"),
      parameters: Map.get(tool, :parameters) || Map.get(tool, "parameters")
    }
  end

  defp tool_projection(tool), do: semantic_value(tool)

  defp message_projection(%Message.User{content: content}),
    do: %{role: :user, content: Enum.map(content, &content_projection/1)}

  defp message_projection(%Message.Assistant{content: content}),
    do: %{role: :assistant, content: Enum.map(content, &content_projection/1)}

  defp message_projection(%Message.ToolResult{} = result) do
    %{
      role: :tool_result,
      tool_call_id: result.tool_call_id,
      tool_name: result.tool_name,
      content: Enum.map(List.wrap(result.content), &content_projection/1)
    }
  end

  defp message_projection(other), do: semantic_value(other)

  defp content_projection(%Content.Text{text: text}), do: %{type: :text, text: text}

  defp content_projection(%Content.Thinking{} = thinking) do
    %{
      type: :thinking,
      thinking: thinking.thinking,
      signature: thinking_signature(thinking.signature),
      redacted: thinking.redacted
    }
  end

  # The base64 payload never enters the projection: it would be counted as text
  # at four bytes per token, inflating a single screenshot into six figures. The
  # SHA-256 digest keeps image identity — the projection also feeds
  # `context_fingerprint/3`, anchor matching, and the websocket delta-upload
  # prefix check — while `bytes` carries the size `estimate_projection/1` prices.
  # `tag_image_block/1` marks the block as harness-built so it (and nothing the
  # model wrote) is eligible for image pricing.
  defp content_projection(%Content.Image{data: data, mime_type: mime}),
    do:
      tag_image_block(%{
        type: :image,
        mime_type: mime,
        digest: :crypto.hash(:sha256, data),
        bytes: byte_size(data)
      })

  defp content_projection(%Content.ToolCall{} = call),
    do: %{type: :tool_call, id: call.id, name: call.name, arguments: call.arguments}

  defp content_projection(other), do: semantic_value(other)

  defp thinking_signature(signature) when is_binary(signature), do: decode_json(signature)
  defp thinking_signature(signature), do: signature

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      {:error, _reason} -> json
    end
  end

  defp provider_options(opts) do
    opts
    |> enumerable_options()
    |> Enum.reject(fn {key, value} -> internal_option?(key) or not semantic_option?(value) end)
    |> Map.new()
  end

  defp enumerable_options(opts) when is_list(opts), do: opts
  defp enumerable_options(opts) when is_map(opts), do: Map.to_list(opts)

  defp internal_option?(key),
    do:
      key in [
        :provider,
        :get_steering,
        :get_follow_up,
        :convert_to_llm,
        :loop,
        :workflow,
        :context_threshold,
        :context_policy,
        :summary_fun,
        :register_resource
      ]

  defp semantic_option?(value) when is_function(value) or is_pid(value) or is_reference(value),
    do: false

  defp semantic_option?(_value), do: true

  defp semantic_value(%_{} = struct), do: struct |> Map.from_struct() |> semantic_value()

  defp semantic_value(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, semantic_value(value)} end)

  defp semantic_value(list) when is_list(list), do: Enum.map(list, &semantic_value/1)

  defp semantic_value(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> semantic_value()

  defp semantic_value(value), do: value

  defp canonical(%_{} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(map) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {key, value} -> {canonical_key(key), canonical(value)} end)
      |> Enum.sort_by(&elem(&1, 0))

    {:map, pairs}
  end

  defp canonical(list) when is_list(list), do: {:list, Enum.map(list, &canonical/1)}

  defp canonical(tuple) when is_tuple(tuple),
    do: {:tuple, tuple |> Tuple.to_list() |> Enum.map(&canonical/1)}

  defp canonical(nil), do: :null
  defp canonical(value) when is_boolean(value), do: {:boolean, value}
  defp canonical(value) when is_atom(value), do: {:atom, Atom.to_string(value)}
  defp canonical(value) when is_binary(value), do: {:binary, value}
  defp canonical(value) when is_integer(value), do: {:integer, value}

  defp canonical(value) when is_float(value),
    do: {:float, :erlang.float_to_binary(value, [:compact])}

  defp canonical(value), do: {:other, inspect(value, limit: 20, printable_limit: 2_000)}

  defp canonical_key(key) when is_binary(key), do: "s:" <> key
  defp canonical_key(key) when is_atom(key), do: "a:" <> Atom.to_string(key)
  defp canonical_key(key), do: "o:" <> inspect(key)

  # Size-scaled cost of every image block reachable in a projection, recognised
  # ONLY by the atom tag `tag_image_block/1` applies at the harness projection
  # sites (`content_projection/1` here, `Request.semantic_item/1` for Codex).
  # A `"type"`-shaped map is deliberately not enough: tool-call arguments are
  # model-written decoded JSON embedded verbatim in the projection, and pricing
  # them as images would let the model inflate — and steer — the estimate.
  @spec image_tokens(term()) :: non_neg_integer()
  defp image_tokens(%{@image_tag => true} = block), do: image_cost(block)

  defp image_tokens(map) when is_map(map),
    do: map |> Map.values() |> Enum.sum_by(&image_tokens/1)

  defp image_tokens(list) when is_list(list), do: Enum.sum_by(list, &image_tokens/1)
  defp image_tokens(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> image_tokens()
  defp image_tokens(_value), do: 0

  defp image_cost(block),
    do: max(@image_token_floor, div(image_bytes(block), @image_bytes_per_token))

  defp image_bytes(%{bytes: bytes}) when is_integer(bytes) and bytes >= 0, do: bytes
  defp image_bytes(%{"bytes" => bytes}) when is_integer(bytes) and bytes >= 0, do: bytes
  defp image_bytes(_block), do: 0

  defp option(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp option(opts, key) when is_map(opts), do: Map.get(opts, key)
end
