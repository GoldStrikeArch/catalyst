defmodule Catalyst.Session.Store do
  @moduledoc """
  Append-only JSONL persistence for a session (PI's JSONL session repo).

  Layout: `~/.catalyst/sessions/<cwd-hash>/<id>.jsonl`. Line 1 is a session
  header; each subsequent line is a `{"type":"message","message":{…}}` entry,
  appended as the single writer (`Catalyst.Session.Server`) sees `message_end`.
  `load/1` folds the lines back into a message list for resume.
  """

  alias Catalyst.{Content, Message, Usage}

  @type handle :: %{id: String.t(), path: String.t(), cwd: String.t()}

  @doc "Root directory for all session logs (override with `config :catalyst, :sessions_root`)."
  def root,
    do: Application.get_env(:catalyst, :sessions_root) || Path.expand("~/.catalyst/sessions")

  @doc "Create a new session file with a header line; returns its handle."
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

    File.write!(path, line(header))

    %{id: id, path: path, cwd: cwd}
  end

  @doc "Append one message as a JSONL line."
  @spec append_message(handle(), Message.t()) :: :ok
  def append_message(%{path: path}, message) do
    File.write!(path, line(%{"type" => "message", "message" => encode(message)}), [:append])
  end

  @doc "Load the messages from a session file (header skipped)."
  @spec load(String.t()) :: [Message.t()]
  def load(path) do
    path
    |> File.stream!()
    |> Enum.flat_map(&decode_line/1)
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
      "stopReason" => to_string(m.stop_reason),
      "errorMessage" => m.error_message,
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

  defp encode_content(content) when is_list(content), do: Enum.map(content, &encode_block/1)

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

  # Details are best-effort JSON; drop anything not encodable rather than crash.
  defp encodable(nil), do: nil

  defp encodable(details) do
    case Jason.encode(details) do
      {:ok, _} -> details
      {:error, _} -> nil
    end
  end

  # ---- decoding -------------------------------------------------------------

  defp decode_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"type" => "message", "message" => m}} -> [decode(m)]
      _ -> []
    end
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
      usage: %Usage{},
      stop_reason: decode_reason(m["stopReason"]),
      error_message: m["errorMessage"],
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

  defp decode_reason(nil), do: :stop
  defp decode_reason(s), do: String.to_existing_atom(s)

  # ---- helpers --------------------------------------------------------------

  defp gen_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp cwd_hash(cwd),
    do: :sha256 |> :crypto.hash(cwd) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp now, do: System.system_time(:millisecond)
end
