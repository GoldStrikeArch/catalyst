defmodule Catalyst.Tools.ShellSession do
  @moduledoc """
  The `shell_session` tool: an interactive PTY shell held open across turns
  (Codex's `exec_command`/`write_stdin` model).

  Gated behind `:computer_use` — unlike one-shot, stdin-less `bash`, a PTY
  session accepts stdin and outlives the tool call, so it can keep an
  authenticated `ssh`/`sudo`/REPL session live. Shells are owned by the
  Catalyst session that started them: other sessions cannot list, write to,
  or read them, and a shell is reaped when its owning session ends (or after
  the idle timeout).
  """
  use Catalyst.Tools.Tool

  alias Catalyst.Tools.{Shell, Truncate}

  @default_yield_ms 2_000
  @max_yield_ms 30_000
  @default_max_bytes 48 * 1024
  @max_max_bytes 256 * 1024

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def capabilities, do: [:computer_use]

  @impl true
  def name, do: "shell_session"

  @impl true
  def description do
    "Interactive PTY shell sessions that stay open across turns (unlike `bash`, which is " <>
      "one-shot and has no stdin). Actions: `start` spawns a shell and returns a session_id " <>
      "plus initial output; `write` sends `chars` to stdin exactly as given — append \"\\n\" " <>
      "yourself to run a command — and returns output collected for up to `yield_ms`; `read` " <>
      "collects pending output without writing; `close` terminates the shell; `list` shows " <>
      "your live sessions. The PTY echoes what you write back into the output and lines end " <>
      "with \\r\\n — seeing your own input is normal. Output per call is capped at `max_bytes` " <>
      "(default #{div(@default_max_bytes, 1024)}KB); unread output is buffered for the next " <>
      "read. Idle sessions are closed automatically. Use this for REPLs, ssh, sudo prompts, " <>
      "and anything interactive; prefer `bash` for ordinary one-shot commands."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["start", "write", "read", "close", "list"],
          "description" => "What to do"
        },
        "session_id" => %{
          "type" => "string",
          "description" => "Shell session id (required for write/read/close)"
        },
        "chars" => %{
          "type" => "string",
          "description" =>
            "Bytes to send to stdin for `write`. No newline is appended; end with \"\\n\" to run a command."
        },
        "yield_ms" => %{
          "type" => "integer",
          "minimum" => 0,
          "maximum" => @max_yield_ms,
          "description" =>
            "How long to collect output before returning (default #{@default_yield_ms}, max #{@max_yield_ms})"
        },
        "max_bytes" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @max_max_bytes,
          "description" => "Cap on returned output bytes (default #{@default_max_bytes})"
        },
        "shell" => %{
          "type" => "string",
          "description" => "Shell executable for `start` (default: $SHELL, /bin/zsh, or /bin/sh)"
        },
        "cwd" => %{
          "type" => "string",
          "description" => "Working directory for `start` (default: the session cwd)"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => "start"} = args, ctx) do
    owner = owner_of(ctx)

    case Shell.start_session(owner, start_opts(args, ctx)) do
      {:ok, id} ->
        collected = collect!(id, owner, args, ctx)
        render(collected, "shell session started: #{id}", id)

      {:error, {:limit_reached, max}} ->
        raise "shell session limit reached (#{max} concurrent); close one with " <>
                ~s(`{"action": "close", "session_id": ...}` first)

      {:error, reason} ->
        raise "shell_session start failed: #{inspect(reason)}"
    end
  end

  def execute(%{"action" => "write", "session_id" => id, "chars" => chars} = args, ctx)
      when is_binary(chars) do
    owner = owner_of(ctx)

    case Shell.send_input(id, owner, chars) do
      :ok -> collect!(id, owner, args, ctx) |> render(nil, id)
      {:error, reason} -> raise_access!(id, reason)
    end
  end

  def execute(%{"action" => "write"} = _args, _ctx),
    do: raise(~s(shell_session write requires "session_id" and "chars"))

  def execute(%{"action" => "read", "session_id" => id} = args, ctx) do
    owner = owner_of(ctx)
    collect!(id, owner, args, ctx) |> render(nil, id)
  end

  def execute(%{"action" => "close", "session_id" => id}, ctx) do
    case Shell.close(id, owner_of(ctx)) do
      :ok -> result("shell session #{id} closed", %{shell_session_id: id, closed: true})
      {:error, reason} -> raise_access!(id, reason)
    end
  end

  def execute(%{"action" => "list"}, ctx) do
    sessions = Shell.list(owner_of(ctx))

    text =
      case sessions do
        [] -> "no live shell sessions"
        _some -> Enum.map_join(sessions, "\n", &describe/1)
      end

    result(text, %{sessions: Enum.map(sessions, &Map.take(&1, [:id, :alive, :exit_status]))})
  end

  def execute(%{"action" => action}, _ctx) when action in ["read", "close"],
    do: raise(~s(shell_session #{action} requires "session_id"))

  def execute(_args, _ctx),
    do: raise(~s(shell_session requires "action": one of start|write|read|close|list))

  # -- helpers ---------------------------------------------------------------

  defp owner_of(ctx), do: Map.get(ctx, :session_id)

  defp describe(info) do
    status =
      case {info.alive, info.exit_status} do
        {true, _status} -> "running"
        {false, nil} -> "closed"
        {false, status} -> "exited (status #{status})"
      end

    "#{info.id}\t#{info.shell}\t#{status}\t#{info.pending_bytes} pending bytes"
  end

  defp start_opts(args, ctx) do
    [cwd: args["cwd"] || Map.get(ctx, :cwd)] ++ shell_opt(args["shell"])
  end

  defp shell_opt(shell) when is_binary(shell) and shell != "", do: [shell: shell]
  defp shell_opt(_absent), do: []

  defp collect!(id, owner, args, ctx) do
    opts = [
      yield_ms: clamp(args["yield_ms"], @default_yield_ms, 0, @max_yield_ms),
      max_bytes: clamp(args["max_bytes"], @default_max_bytes, 1, @max_max_bytes),
      on_chunk: stream_reporter(ctx)
    ]

    case Shell.collect(id, owner, opts) do
      {:ok, collected} -> collected
      {:error, {:shell_down, _reason, output}} -> down_result(output)
      {:error, reason} -> raise_access!(id, reason)
    end
  end

  defp down_result(output),
    do: %{output: output, exit_status: nil, alive: false, truncated: false, dropped_bytes: 0}

  @spec raise_access!(String.t(), term()) :: no_return()
  defp raise_access!(id, :not_found), do: raise("unknown shell session: #{id}")

  defp raise_access!(id, :not_owner),
    do: raise("shell session #{id} belongs to a different Catalyst session")

  defp raise_access!(id, :busy),
    do: raise("shell session #{id} is already being read; try again")

  defp raise_access!(id, {:shell_exited, status}),
    do: raise("shell session #{id} has exited (status #{inspect(status)}); close it")

  defp raise_access!(id, reason),
    do: raise("shell_session #{id} failed: #{inspect(reason)}")

  defp render(collected, banner, id) do
    text =
      collected.output
      |> Truncate.scrub_utf8()
      |> prepend_banner(banner)
      |> append_notices(collected)

    details = %{
      shell_session_id: id,
      alive: collected.alive,
      exit_status: collected.exit_status,
      bytes: byte_size(collected.output),
      truncated: collected.truncated,
      dropped_bytes: collected.dropped_bytes
    }

    result(text, details)
  end

  defp prepend_banner(text, nil), do: text
  defp prepend_banner(text, banner), do: "[#{banner}]\n" <> text

  defp append_notices(text, collected) do
    text
    |> append_when(
      collected.dropped_bytes > 0,
      "\n... [#{collected.dropped_bytes} bytes of unread output dropped]"
    )
    |> append_when(collected.truncated, "\n... [output capped; call read again for the rest]")
    |> append_when(
      collected.exit_status != nil,
      "\n[shell exited with status #{collected.exit_status}]"
    )
  end

  defp append_when(text, false, _notice), do: text
  defp append_when(text, true, notice), do: text <> notice

  defp clamp(value, _default, min, max) when is_integer(value),
    do: value |> max(min) |> min(max)

  defp clamp(_absent, default, _min, _max), do: default

  @report_interval_ms 100
  @partial_tail_bytes 400

  # The same 100ms-throttled bounded-tail streaming as `Tools.Bash`: chunks
  # arrive as messages in this tool process (the collect loop runs here), so
  # the throttle state lives in this process's dictionary and is re-initialized
  # per call.
  defp stream_reporter(ctx) do
    report = Map.get(ctx, :report)
    key = {__MODULE__, :stream_state}
    Process.put(key, {nil, ""})

    fn chunk ->
      {last_ms, tail} = Process.get(key, {nil, ""})
      tail = take_tail(tail <> chunk, @partial_tail_bytes)
      now = System.monotonic_time(:millisecond)

      case is_function(report, 1) and
             (last_ms == nil or now - last_ms >= @report_interval_ms) do
        true ->
          report.(%{output: Truncate.scrub_utf8(tail)})
          Process.put(key, {now, tail})

        false ->
          Process.put(key, {last_ms, tail})
      end
    end
  end

  defp take_tail(bin, max) when byte_size(bin) <= max, do: bin
  defp take_tail(bin, max), do: binary_part(bin, byte_size(bin) - max, max)
end
