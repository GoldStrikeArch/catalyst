defmodule Catalyst.Session.Store do
  @moduledoc """
  Append-only JSONL persistence for a session (PI's JSONL session repo).

  Layout: `~/.catalyst/sessions/<cwd-hash>/<id>.jsonl`. Line 1 is a session
  header; each subsequent line is a `{"type":"message","message":{…}}` entry,
  appended as the single writer (`Catalyst.Session.Server`) sees `message_end`.
  `load/1` folds the lines back into a message list for resume.
  """

  alias Catalyst.{Content, Message, Usage}

  require Logger

  @type handle :: %{id: String.t(), path: String.t(), cwd: String.t()}

  @doc "Root directory for all session logs (override with `config :catalyst, :sessions_root`)."
  def root,
    do: Application.get_env(:catalyst, :sessions_root) || Path.expand("~/.catalyst/sessions")

  @doc """
  Open the session file for an id, creating it with a header line if it does
  not exist yet; returns its handle. An existing file is left untouched so a
  crash-restarted `Session.Server` can resume it via `load/1`.
  """
  @spec new(String.t(), keyword()) :: handle()
  def new(cwd, opts \\ []) do
    id = Keyword.get(opts, :id) || gen_id()
    dir = Path.join(root(), cwd_hash(cwd))
    File.mkdir_p!(dir)
    path = Path.join(dir, id <> ".jsonl")

    header = %{
      "type" => "session",
      "version" => 1,
      "id" => id,
      "cwd" => cwd,
      "timestamp" => now()
    }

    unless File.exists?(path), do: File.write!(path, line(header))

    %{id: id, path: path, cwd: cwd}
  end

  @doc """
  Append one message as a JSONL line. Best-effort, like `load/1`: the session
  server (the single caller) appends inline while folding run events, so an
  encode or disk failure is logged and swallowed rather than crashing the run.
  """
  @spec append_message(handle(), Message.t()) :: :ok
  def append_message(handle, message) do
    append_line(handle, fn -> %{"type" => "message", "message" => encode(message)} end)
  end

  @doc """
  Append a reset marker. `load/1` discards every message before the last
  marker, so a session reset survives crash-restarts without rewriting the
  append-only file. Best-effort, like `append_message/2`.
  """
  @spec append_reset(handle()) :: :ok
  def append_reset(handle) do
    append_line(handle, fn -> %{"type" => "reset"} end)
  end

  # Encode + write inside the rescue, so neither a Jason failure (tool results
  # can carry values JSON can't represent) nor a disk error propagates into the
  # session server.
  defp append_line(%{id: id, path: path}, build) do
    File.write!(path, line(build.()), [:append])
  rescue
    error ->
      Logger.warning("session #{id}: failed to append to #{path}: #{Exception.message(error)}")
      :ok
  end

  @doc "Load the messages from a session file (header skipped, last reset honored)."
  @spec load(String.t()) :: [Message.t()]
  def load(path) do
    path
    |> File.stream!()
    |> Enum.reduce([], &fold_line/2)
    |> Enum.reverse()
  end

  # ---- encoding -------------------------------------------------------------

  defp line(map), do: Jason.encode!(map) <> "\n"

  def encode(%Message.User{content: c, timestamp: ts}) do
    %{"role" => "user", "content" => encode_content(c), "timestamp" => ts}
  end

  def encode(%Message.Assistant{} = m) do
    %{
      "role" => "assistant",
      "content" => encode_content(m.content),
      "api" => m.api,
      "provider" => m.provider,
      "model" => m.model,
      "usage" => encode_usage(m.usage),
      "stopReason" => to_string(m.stop_reason),
      "errorMessage" => m.error_message,
      "responseId" => m.response_id,
      "timestamp" => m.timestamp
    }
  end

  def encode(%Message.ToolResult{} = m) do
    %{
      "role" => "toolResult",
      "toolCallId" => m.tool_call_id,
      "toolName" => m.tool_name,
      "content" => encode_content(m.content),
      "isError" => m.is_error,
      "details" => encodable(m.details),
      "timestamp" => m.timestamp
    }
  end

  defp encode_usage(nil), do: nil

  defp encode_usage(%Usage{} = u) do
    %{
      "input" => u.input,
      "output" => u.output,
      "cacheRead" => u.cache_read,
      "cacheWrite" => u.cache_write,
      "totalTokens" => u.total_tokens,
      "cost" => u.cost
    }
  end

  defp encode_content(content) when is_list(content), do: Enum.map(content, &encode_block/1)

  # Tool results are duck-typed (extension/LLM-authored tools return arbitrary
  # shapes), so non-list content is wrapped as a single block rather than crash.
  defp encode_content(other), do: [encode_block(other)]

  defp encode_block(%Content.Text{text: t}), do: %{"type" => "text", "text" => t}

  defp encode_block(%Content.Thinking{} = b),
    do: %{
      "type" => "thinking",
      "thinking" => b.thinking,
      "signature" => b.signature,
      "redacted" => b.redacted
    }

  defp encode_block(%Content.Image{data: d, mime_type: mt}),
    do: %{"type" => "image", "data" => d, "mimeType" => mt}

  defp encode_block(%Content.ToolCall{id: id, name: n, arguments: a}),
    do: %{"type" => "toolCall", "id" => id, "name" => n, "arguments" => a}

  # Unknown block shapes degrade to inspected text so the line stays decodable.
  defp encode_block(other), do: %{"type" => "text", "text" => inspect(other)}

  # Details are best-effort JSON; drop anything not encodable rather than crash.
  defp encodable(nil), do: nil

  defp encodable(details) do
    case Jason.encode(details) do
      {:ok, _} -> details
      {:error, _} -> nil
    end
  end

  # ---- decoding -------------------------------------------------------------

  # Best-effort: a corrupt or forward-versioned line must not make the whole
  # session unloadable, so decode failures skip the line. The accumulator is
  # newest-first; a reset marker drops everything seen so far.
  defp fold_line(line, acc) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"type" => "message", "message" => m}} -> [decode(m) | acc]
      {:ok, %{"type" => "reset"}} -> []
      _ -> acc
    end
  rescue
    _ -> acc
  end

  @doc "Decode a JSON message map back into a struct."
  def decode(%{"role" => "user"} = m),
    do: %Message.User{content: decode_content(m["content"]), timestamp: m["timestamp"]}

  def decode(%{"role" => "assistant"} = m) do
    %Message.Assistant{
      content: decode_content(m["content"]),
      api: m["api"],
      provider: m["provider"],
      model: m["model"],
      usage: decode_usage(m["usage"]),
      stop_reason: decode_reason(m["stopReason"]),
      error_message: m["errorMessage"],
      response_id: m["responseId"],
      timestamp: m["timestamp"]
    }
  end

  def decode(%{"role" => "toolResult"} = m) do
    %Message.ToolResult{
      tool_call_id: m["toolCallId"],
      tool_name: m["toolName"],
      content: decode_content(m["content"]),
      details: m["details"],
      is_error: m["isError"] || false,
      timestamp: m["timestamp"]
    }
  end

  defp decode_usage(%{} = u) do
    %Usage{
      input: u["input"] || 0,
      output: u["output"] || 0,
      cache_read: u["cacheRead"] || 0,
      cache_write: u["cacheWrite"] || 0,
      total_tokens: u["totalTokens"] || 0,
      cost: u["cost"] || 0.0
    }
  end

  defp decode_usage(_), do: %Usage{}

  defp decode_content(blocks) when is_list(blocks), do: Enum.map(blocks, &decode_block/1)
  defp decode_content(_), do: []

  defp decode_block(%{"type" => "text", "text" => t}), do: %Content.Text{text: t}

  defp decode_block(%{"type" => "thinking"} = b),
    do: %Content.Thinking{
      thinking: b["thinking"],
      signature: b["signature"],
      redacted: b["redacted"] || false
    }

  defp decode_block(%{"type" => "image"} = b),
    do: %Content.Image{data: b["data"], mime_type: b["mimeType"]}

  defp decode_block(%{"type" => "toolCall"} = b),
    do: %Content.ToolCall{id: b["id"], name: b["name"], arguments: b["arguments"] || %{}}

  defp decode_reason(s) when s in ~w(stop length tool_use error aborted),
    do: String.to_existing_atom(s)

  defp decode_reason(_), do: :stop

  # ---- helpers --------------------------------------------------------------

  defp gen_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp cwd_hash(cwd),
    do: :sha256 |> :crypto.hash(cwd) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp now, do: System.system_time(:millisecond)
end
