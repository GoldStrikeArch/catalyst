defmodule Catalyst.Session.Store.Codec do
  @moduledoc """
  Encodes Catalyst session messages and models to their JSONL map shapes and
  decodes those maps back into domain structs.

  File traversal and append-only persistence remain owned by
  `Catalyst.Session.Store`; this module owns only the pure wire conversion.
  """

  alias Catalyst.{Content, Message, Model, Usage}

  @type decode_error ::
          {:invalid_message, term()}
          | {:unknown_role, term()}
          | {:invalid_content, term()}
          | {:invalid_content_block, term()}

  @doc "Encode a session message into its JSON-compatible map representation."
  @spec encode(Message.t()) :: map()
  def encode(%Message.User{content: content, timestamp: timestamp}) do
    %{"role" => "user", "content" => encode_content(content), "timestamp" => timestamp}
  end

  def encode(%Message.Assistant{} = message) do
    %{
      "role" => "assistant",
      "content" => encode_content(message.content),
      "api" => message.api,
      "provider" => message.provider,
      "model" => message.model,
      "usage" => encode_usage(message.usage),
      "stopReason" => to_string(message.stop_reason),
      "errorMessage" => message.error_message,
      "responseId" => message.response_id,
      "timestamp" => message.timestamp
    }
  end

  def encode(%Message.ToolResult{} = message) do
    %{
      "role" => "toolResult",
      "toolCallId" => message.tool_call_id,
      "toolName" => message.tool_name,
      "content" => encode_content(message.content),
      "isError" => message.is_error,
      "details" => encodable(message.details),
      "timestamp" => message.timestamp
    }
  end

  @doc "Decode a persisted JSON message map back into a session message."
  @spec decode(term()) :: {:ok, Message.t()} | {:error, decode_error()}
  def decode(%{"role" => "user"} = message) do
    with {:ok, content} <- decode_content(message["content"]) do
      {:ok, %Message.User{content: content, timestamp: message["timestamp"]}}
    end
  end

  def decode(%{"role" => "assistant"} = message) do
    with {:ok, content} <- decode_content(message["content"]) do
      {:ok,
       %Message.Assistant{
         content: content,
         api: message["api"],
         provider: message["provider"],
         model: message["model"],
         usage: decode_usage(message["usage"]),
         stop_reason: decode_reason(message["stopReason"]),
         error_message: message["errorMessage"],
         response_id: message["responseId"],
         timestamp: message["timestamp"]
       }}
    end
  end

  def decode(%{"role" => "toolResult"} = message) do
    with {:ok, content} <- decode_content(message["content"]) do
      {:ok,
       %Message.ToolResult{
         tool_call_id: message["toolCallId"],
         tool_name: message["toolName"],
         content: content,
         details: message["details"],
         is_error: message["isError"] || false,
         timestamp: message["timestamp"]
       }}
    end
  end

  def decode(%{"role" => role}), do: {:error, {:unknown_role, role}}
  def decode(invalid), do: {:error, {:invalid_message, invalid}}

  @doc "Encode a model descriptor for a persisted `model_change` entry."
  @spec encode_model(Model.t()) :: map()
  def encode_model(%Model{} = model) do
    %{
      "id" => model.id,
      "name" => model.name,
      "api" => model.api,
      "provider" => model.provider,
      "baseUrl" => model.base_url,
      "reasoning" => model.reasoning,
      "input" => Enum.map(model.input || [], &to_string/1),
      "contextWindow" => model.context_window,
      "maxContextWindow" => model.max_context_window,
      "effectiveContextWindowPercent" => model.effective_context_window_percent,
      "autoCompactTokenLimit" => model.auto_compact_token_limit,
      "contextWindowSource" => encode_context_window_source(model.context_window_source),
      "maxTokens" => model.max_tokens
    }
  end

  @doc "Decode a persisted model map, returning `:error` for an invalid shape."
  @spec decode_model(term()) :: {:ok, Model.t()} | :error
  def decode_model(%{"id" => id} = model) when is_binary(id) do
    {:ok,
     %Model{
       id: id,
       name: model["name"],
       api: model["api"],
       provider: model["provider"],
       base_url: model["baseUrl"],
       reasoning: model["reasoning"],
       input: decode_model_input(model["input"]),
       context_window: model["contextWindow"],
       max_context_window: model["maxContextWindow"],
       effective_context_window_percent: model["effectiveContextWindowPercent"],
       auto_compact_token_limit: model["autoCompactTokenLimit"],
       context_window_source: decode_context_window_source(model["contextWindowSource"]),
       max_tokens: model["maxTokens"]
     }}
  end

  def decode_model(_malformed), do: :error

  defp decode_model_input(input) when is_list(input) do
    Enum.flat_map(input, fn
      "text" -> [:text]
      "image" -> [:image]
      _unknown -> []
    end)
  end

  defp decode_model_input(_input), do: [:text]

  defp encode_usage(nil), do: nil

  defp encode_usage(%Usage{} = usage) do
    %{
      "input" => usage.input,
      "output" => usage.output,
      "cacheRead" => usage.cache_read,
      "cacheWrite" => usage.cache_write,
      "totalTokens" => usage.total_tokens,
      "cost" => usage.cost,
      "contextDigest" => usage.context_digest
    }
  end

  defp encode_content(content) when is_list(content), do: Enum.map(content, &encode_block/1)

  # Tool results are duck-typed (extension/LLM-authored tools return arbitrary
  # shapes), so non-list content is wrapped as a single block rather than crash.
  defp encode_content(other), do: [encode_block(other)]

  defp encode_block(%Content.Text{text: text}), do: %{"type" => "text", "text" => text}

  defp encode_block(%Content.Thinking{} = block) do
    %{
      "type" => "thinking",
      "thinking" => block.thinking,
      "signature" => block.signature,
      "redacted" => block.redacted
    }
  end

  defp encode_block(%Content.Image{data: data, mime_type: mime_type}) do
    %{"type" => "image", "data" => data, "mimeType" => mime_type}
  end

  defp encode_block(%Content.ToolCall{id: id, name: name, arguments: arguments}) do
    %{"type" => "toolCall", "id" => id, "name" => name, "arguments" => arguments}
  end

  # Unknown block shapes degrade to inspected text so the line stays decodable.
  defp encode_block(other), do: %{"type" => "text", "text" => inspect(other)}

  # Details are best-effort JSON; drop anything not encodable rather than crash.
  defp encodable(nil), do: nil

  defp encodable(details) do
    case Jason.encode(details) do
      {:ok, _encoded} -> details
      {:error, _reason} -> nil
    end
  end

  defp decode_usage(%{} = usage) do
    %Usage{
      input: usage["input"] || 0,
      output: usage["output"] || 0,
      cache_read: usage["cacheRead"] || 0,
      cache_write: usage["cacheWrite"] || 0,
      total_tokens: usage["totalTokens"] || 0,
      cost: usage["cost"] || 0.0,
      context_digest: usage["contextDigest"]
    }
  end

  defp decode_usage(_usage), do: %Usage{}

  defp decode_content(nil), do: {:ok, []}

  defp decode_content(blocks) when is_list(blocks) do
    blocks
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, acc} ->
      case decode_block(block) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end)
  end

  defp decode_content(invalid), do: {:error, {:invalid_content, invalid}}

  defp decode_block(%{"type" => "text", "text" => text}),
    do: {:ok, %Content.Text{text: text}}

  defp decode_block(%{"type" => "thinking"} = block) do
    {:ok,
     %Content.Thinking{
       thinking: block["thinking"],
       signature: block["signature"],
       redacted: block["redacted"] || false
     }}
  end

  defp decode_block(%{"type" => "image"} = block) do
    {:ok, %Content.Image{data: block["data"], mime_type: block["mimeType"]}}
  end

  defp decode_block(%{"type" => "toolCall"} = block) do
    {:ok,
     %Content.ToolCall{
       id: block["id"],
       name: block["name"],
       arguments: block["arguments"] || %{}
     }}
  end

  defp decode_block(invalid), do: {:error, {:invalid_content_block, invalid}}

  defp decode_reason(reason) when reason in ~w(stop length tool_use error aborted),
    do: String.to_existing_atom(reason)

  defp decode_reason(_reason), do: :stop

  defp encode_context_window_source(nil), do: nil
  defp encode_context_window_source(source), do: to_string(source)

  defp decode_context_window_source(source)
       when source in ~w(session catalog persisted fallback),
       do: String.to_existing_atom(source)

  defp decode_context_window_source(_source), do: nil
end
