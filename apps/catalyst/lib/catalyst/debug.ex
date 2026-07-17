defmodule Catalyst.Debug do
  @moduledoc """
  Lightweight per-session debug log for active development. When enabled (default
  on; disable with `CATALYST_DEBUG=0` or `config :catalyst, debug_log: false`),
  every agent-loop step, tool call, and LLM request/response (truncated) is
  appended to `~/.catalyst/debug/<session_id>.log`, and `latest.log` points at the
  most recent session. The agent can read it with the `read_log` tool to
  self-diagnose failures.
  """

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message}

  @max 4_000

  @doc "Whether debug logging is on."
  def enabled? do
    case System.get_env("CATALYST_DEBUG") do
      v when v in ["0", "false", "off"] -> false
      _ -> Application.get_env(:catalyst, :debug_log, true)
    end
  end

  @doc "Debug directory (`~/.catalyst/debug`)."
  def dir, do: Path.join(Path.dirname(Catalyst.Extensions.dir()), "debug")

  @doc "Log file for a session id."
  def path(session_id), do: Path.join(dir(), "#{session_id}.log")

  @doc "Symlink to the most recent session's log."
  def latest_path, do: Path.join(dir(), "latest.log")

  @doc "Append a `[category] message` line to a session's log (no-op if disabled or no id)."
  def log(session_id, category, message)

  def log(session_id, category, message) when is_binary(session_id) do
    if enabled?() do
      File.mkdir_p!(dir())
      File.write!(path(session_id), "#{ts()} [#{category}] #{message}\n", [:append])
    end

    :ok
  rescue
    _ -> :ok
  end

  def log(_session_id, _category, _message), do: :ok

  @doc "Log one agent-loop event (streaming deltas are skipped to keep the log readable)."
  def log_event(session_id, event) do
    case format_event(event) do
      nil -> :ok
      text -> log(session_id, "event", text)
    end
  end

  @doc "Point `latest.log` at this session's log. Call on session start."
  def mark_latest(session_id) when is_binary(session_id) do
    if enabled?() do
      File.mkdir_p!(dir())
      _ = File.rm(latest_path())
      _ = File.ln_s(path(session_id), latest_path())
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "Truncate a binary or term for logging."
  def truncate(term, max \\ @max)

  def truncate(bin, max) when is_binary(bin) do
    if byte_size(bin) > max,
      do: binary_part(bin, 0, max) <> "…(+#{byte_size(bin) - max}B)",
      else: bin
  end

  def truncate(term, max), do: term |> inspect(limit: :infinity, printable_limit: max) |> truncate(max)

  # ---- event formatting -----------------------------------------------------

  defp format_event(%Event.AgentStart{}), do: "agent_start"
  defp format_event(%Event.AgentEnd{}), do: "agent_end"
  defp format_event(%Event.TurnStart{}), do: "turn_start"
  defp format_event(%Event.TurnEnd{}), do: "turn_end"
  defp format_event(%Event.MessageStart{message: m}), do: "message_start #{role(m)}"
  defp format_event(%Event.MessageEnd{message: m}), do: "message_end #{role(m)} #{summarize(m)}"
  defp format_event(%Event.ToolExecutionStart{name: n, args: a}), do: "tool_start #{n} #{truncate(inspect(a), 800)}"

  defp format_event(%Event.ToolExecutionEnd{name: n, is_error: err, result: r}),
    do: "tool_end #{n} error=#{err} #{truncate(Content.text_of(r.content), 800)}"

  # Streaming deltas are too noisy; the final message_end carries the full text.
  defp format_event(%Event.MessageUpdate{}), do: nil
  defp format_event(other), do: truncate(other)

  defp role(%Message.User{}), do: "user"
  defp role(%Message.Assistant{}), do: "assistant"
  defp role(%Message.ToolResult{tool_name: n}), do: "tool_result(#{n})"
  defp role(_), do: "?"

  defp summarize(%Message.ToolResult{} = m), do: "error=#{m.is_error} #{truncate(Content.text_of(m.content), 800)}"

  defp summarize(%{} = m) do
    text = m |> Map.get(:content, []) |> Content.text_of()
    stop = Map.get(m, :stop_reason)
    "stop=#{inspect(stop)} #{truncate(text, 1200)}"
  end

  defp summarize(_), do: ""

  defp ts, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
