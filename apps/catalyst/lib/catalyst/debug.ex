defmodule Catalyst.Debug do
  @moduledoc """
  Lightweight per-session debug log for active development. When enabled (default
  on; disable with `CATALYST_DEBUG=0` or `config :catalyst, debug_log: false`),
  every agent-loop step, tool call, and LLM request/response (truncated) is
  appended to `~/.catalyst/debug/<session_id>.log`, and `latest.log` points at the
  most recent session. The agent can read it with the `read_log` tool to
  self-diagnose failures. `init/0` snapshots the enabled setting at application
  boot; call it again after intentionally changing the setting at runtime.
  """

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message, Paths}
  alias Catalyst.Tools.Truncate

  @max 4_000
  @enabled_key {__MODULE__, :enabled}
  @prepared_dir_key {__MODULE__, :prepared_dir}

  @doc "Cache process-wide debug configuration; called at application boot."
  @spec init() :: :ok
  def init do
    :persistent_term.put(@enabled_key, configured_enabled?())
    :persistent_term.erase(@prepared_dir_key)
    :ok
  end

  @doc "Whether debug logging is on."
  @spec enabled?() :: boolean()
  def enabled? do
    case :persistent_term.get(@enabled_key, :unset) do
      :unset -> configured_enabled?()
      enabled -> enabled
    end
  end

  defp configured_enabled? do
    case System.get_env("CATALYST_DEBUG") do
      v when v in ["0", "false", "off"] -> false
      _ -> Application.get_env(:catalyst, :debug_log, true)
    end
  end

  @doc "Debug directory (`~/.catalyst/debug`)."
  @spec dir() :: Path.t()
  def dir, do: Paths.debug()

  @doc "Log file for a session id."
  @spec path(String.t()) :: Path.t()
  def path(session_id), do: Path.join(dir(), "#{session_id}.log")

  @doc "Symlink to the most recent session's log."
  @spec latest_path() :: Path.t()
  def latest_path, do: Path.join(dir(), "latest.log")

  @doc "Append a `[category] message` line to a session's log (no-op if disabled or no id)."
  @spec log(String.t() | nil, String.t(), String.t()) :: :ok
  def log(session_id, category, message)

  def log(session_id, category, message) when is_binary(session_id) do
    case enabled?() do
      true ->
        ensure_debug_dir()

        line =
          "#{ts()} [#{Truncate.scrub_utf8(category)}] #{Truncate.scrub_utf8(message)}\n"

        File.write!(path(session_id), line, [:append])

      false ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  def log(_session_id, _category, _message), do: :ok

  @doc "Log one agent-loop event (streaming deltas are skipped to keep the log readable)."
  @spec log_event(String.t() | nil, struct()) :: :ok
  def log_event(session_id, event) do
    case format_event(event) do
      nil -> :ok
      text -> log(session_id, "event", text)
    end
  end

  @doc "Point `latest.log` at this session's log. Call on session start."
  @spec mark_latest(String.t()) :: :ok
  def mark_latest(session_id) when is_binary(session_id) do
    case enabled?() do
      true ->
        ensure_debug_dir()
        _ = File.rm(latest_path())
        _ = File.ln_s(path(session_id), latest_path())

      false ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "Truncate a binary or term for logging."
  @spec truncate(term(), pos_integer()) :: String.t()
  def truncate(term, max \\ @max)

  def truncate(bin, max) when is_binary(bin) do
    bin = Truncate.scrub_utf8(bin)

    case byte_size(bin) > max do
      true ->
        {prefix, _info} = Truncate.head(bin, max_bytes: max, max_lines: max + 1)
        prefix <> "…(+#{byte_size(bin) - byte_size(prefix)}B)"

      false ->
        bin
    end
  end

  def truncate(term, max),
    do: term |> inspect(limit: 100, printable_limit: max) |> truncate(max)

  defp ensure_debug_dir do
    debug_dir = dir()

    case :persistent_term.get(@prepared_dir_key, :unset) do
      ^debug_dir ->
        case File.dir?(debug_dir) do
          true -> :ok
          false -> prepare_debug_dir(debug_dir)
        end

      _other ->
        prepare_debug_dir(debug_dir)
    end
  end

  defp prepare_debug_dir(debug_dir) do
    File.mkdir_p!(debug_dir)
    :persistent_term.put(@prepared_dir_key, debug_dir)
  end

  # ---- event formatting -----------------------------------------------------

  defp format_event(%Event.AgentStart{}), do: "agent_start"
  defp format_event(%Event.AgentEnd{}), do: "agent_end"
  defp format_event(%Event.TurnStart{}), do: "turn_start"
  defp format_event(%Event.TurnEnd{}), do: "turn_end"
  defp format_event(%Event.MessageStart{message: m}), do: "message_start #{role(m)}"
  defp format_event(%Event.MessageEnd{message: m}), do: "message_end #{role(m)} #{summarize(m)}"

  defp format_event(%Event.ToolExecutionStart{name: n, args: a}),
    do: "tool_start #{n} #{truncate(inspect(a), 800)}"

  defp format_event(%Event.ToolExecutionEnd{name: n, is_error: err, result: r}),
    do: "tool_end #{n} error=#{err} #{truncate(Content.text_of(r.content), 800)}"

  # Streaming deltas are too noisy; the final message_end carries the full text.
  defp format_event(%Event.MessageUpdate{}), do: nil
  defp format_event(other), do: truncate(other)

  defp role(%Message.User{}), do: "user"
  defp role(%Message.Assistant{}), do: "assistant"
  defp role(%Message.ToolResult{tool_name: n}), do: "tool_result(#{n})"
  defp role(_), do: "?"

  defp summarize(%Message.ToolResult{} = m),
    do: "error=#{m.is_error} #{truncate(Content.text_of(m.content), 800)}"

  defp summarize(%{} = m) do
    text = m |> Map.get(:content, []) |> Content.text_of()
    stop = Map.get(m, :stop_reason)
    "stop=#{inspect(stop)} #{truncate(text, 1200)}"
  end

  defp summarize(_), do: ""

  defp ts, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
