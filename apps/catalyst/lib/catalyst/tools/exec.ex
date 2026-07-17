defmodule Catalyst.Tools.Exec do
  @moduledoc """
  Two shell-out modes (PI's tool execution backends):

    * `collect/3` — run a binary to completion via a `Port`, capture stdout
      (stderr merged), parse after exit. Used by ripgrep/fd/sd/ast-grep.
    * `bash/2` — run a shell command under the muontrap wrapper binary so a
      timeout or an aborted run kills the whole child process tree, not just
      the shell. Shares `collect/3`'s bounded loop, so bash output is capped
      instead of accumulating unbounded. Used by bash.
  """

  @default_timeout 120_000

  # bash/2's default :max_output_bytes. Bash output is tail-truncated to
  # 2000 lines / 50KB (Truncate.tail) before it reaches the model, so 4MB
  # keeps ~80x the largest useful tail while preventing a `yes`-style command
  # from buffering gigabytes in the agent process until its timeout (the old
  # MuonTrap.cmd path accumulated the child's entire output). Half of
  # ripgrep's 8MB cap — rg output is parsed for matches; bash output is only
  # tailed.
  @bash_max_output_bytes 4 * 1024 * 1024

  @type collect_result ::
          {:ok, %{:out => String.t(), :status => integer(), optional(:truncated) => true}}
          | {:error, term()}

  @doc "Default cap on accumulated bash output (see `bash/2`)."
  @spec bash_max_output_bytes() :: pos_integer()
  def bash_max_output_bytes, do: @bash_max_output_bytes

  @doc """
  Run `path` with `args` to completion. Options: `:cwd`, `:timeout` (ms),
  `:env` (list of `{name, value}`), `:max_output_bytes` (cap on accumulated
  output). stderr is merged into stdout.

  When `:max_output_bytes` is exceeded the child is killed and
  `{:ok, %{out: partial, status: 0, truncated: true}}` is returned. The
  `:truncated` key is present **only** on a capped result; uncapped results
  keep the plain `%{out, status}` shape.
  """
  @spec collect(String.t(), [String.t()], keyword()) :: collect_result()
  def collect(path, args, opts \\ []) do
    case run(path, args, opts, :direct) do
      # collect/3's contract: a timeout discards the partial output.
      {:error, {:timeout, _partial}} -> {:error, :timeout}
      other -> other
    end
  end

  @doc """
  `collect/3` for the exec-style tools: returns the result map when the exit
  status is in `opts[:ok_statuses]` (default `[0]`), and raises the uniform
  tool-facing error otherwise. `label` names the tool in the message.
  """
  @spec collect!(String.t(), String.t(), [String.t()], keyword()) :: map()
  def collect!(label, path, args, opts \\ []) do
    {ok_statuses, opts} = Keyword.pop(opts, :ok_statuses, [0])

    case collect(path, args, opts) do
      {:ok, %{out: out, status: status} = res} ->
        if status in ok_statuses do
          res
        else
          raise "#{label} error (status #{status}): #{String.slice(out, 0, 200)}"
        end

      {:error, reason} ->
        raise "#{label} failed: #{inspect(reason)}"
    end
  end

  @doc """
  Append the shared "output capped" notice when `capped?` — for tools whose
  child was killed at `:max_output_bytes` (the result map's `:truncated` key).
  """
  @spec append_capped_notice(String.t(), boolean(), pos_integer(), String.t()) :: String.t()
  def append_capped_notice(text, false = _capped?, _max_bytes, _hint), do: text

  def append_capped_notice(text, true = _capped?, max_bytes, hint) do
    text <> "\n... [output capped at #{div(max_bytes, 1024 * 1024)}MB; #{hint}]"
  end

  @doc """
  Run a shell command. Options: `:cwd`, `:timeout` (ms, default 120_000),
  `:env`, `:max_output_bytes` (default `bash_max_output_bytes/0`).
  Returns `{:ok, %{out, status}}` — with `truncated: true` when the output
  cap killed the command early — or `{:error, {:timeout, partial_out}}`, so
  partial output is preserved on timeout.

  The command runs under the muontrap wrapper so that hitting the timeout or
  the output cap kills the whole child process tree: closing the wrapper's
  port makes it SIGTERM (then SIGKILL) its child, which a plain port close
  would leave running. Runs in the calling process — a raise becomes
  `{:error, exception}` instead of killing a linked caller.
  """
  @spec bash(String.t(), keyword()) :: collect_result() | {:error, {:timeout, String.t()}}
  def bash(command, opts \\ []) do
    # The tool is named "bash", but on Debian-family systems `sh` is dash and
    # bashisms would fail — resolve real bash when present. A per-call
    # find_executable is a cheap PATH scan.
    shell = System.find_executable("bash") || "sh"

    # Wrapper CLI (deps/muontrap/c_src/muontrap.c): `[flags] -- program args`.
    # --capture-output forwards the child's stdout through the port (it is
    # sent to /dev/null otherwise); --capture-stderr additionally merges the
    # child's stderr into that stream. The wrapper flow-controls the stream:
    # it forwards at most a 10KB window and waits for ack bytes on its stdin
    # (collect_loop acks in :muontrap mode). MuonTrap.cmd/3 itself always
    # execs this same wrapper on every platform — the binary is compiled when
    # the dep builds, so no fallback path is needed.
    args = ["--capture-output", "--capture-stderr", "--", shell, "-c", command]

    opts = Keyword.put_new(opts, :max_output_bytes, @bash_max_output_bytes)
    run(MuonTrap.muontrap_path(), args, opts, :muontrap)
  rescue
    e -> {:error, e}
  end

  defp run(path, args, opts, mode) do
    cwd = Keyword.get(opts, :cwd) || File.cwd!()
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_bytes = Keyword.get(opts, :max_output_bytes, :infinity)

    port_opts =
      [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        {:args, args},
        {:cd, cwd}
      ] ++ env_opt(opts)

    try do
      port = Port.open({:spawn_executable, path}, port_opts)
      deadline = System.monotonic_time(:millisecond) + timeout
      notify = Keyword.get(opts, :on_output)
      collect_loop(port, [], 0, deadline, max_bytes, mode, notify)
    rescue
      e -> {:error, e}
    end
  end

  defp env_opt(opts) do
    case Keyword.get(opts, :env) do
      nil -> []
      env -> [{:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}]
    end
  end

  # The timeout is an absolute deadline: a process emitting output forever
  # still gets killed when its budget runs out. Output is also bounded by
  # max_bytes: past the cap the child is killed and the partial output is
  # returned as a truncated success. The timeout result carries the partial
  # output so bash/2 can surface it; collect/3 drops it. `notify` (the
  # `:on_output` option) sees each chunk as it arrives — crash-isolated, so a
  # broken observer can't fail the command.
  defp collect_loop(port, acc, bytes, deadline, max_bytes, mode, notify) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        case over_budget?(bytes + byte_size(data), max_bytes) do
          true ->
            kill_port(port, mode)
            drain_port(port)
            {:ok, %{out: scrub(IO.iodata_to_binary([acc, data])), status: 0, truncated: true}}

          false ->
            safe_notify(notify, data)
            ack(port, byte_size(data), mode)

            collect_loop(
              port,
              [acc, data],
              bytes + byte_size(data),
              deadline,
              max_bytes,
              mode,
              notify
            )
        end

      {^port, {:exit_status, status}} ->
        {:ok, %{out: scrub(IO.iodata_to_binary(acc)), status: status}}
    after
      remaining ->
        kill_port(port, mode)
        drain_port(port)
        {:error, {:timeout, scrub(IO.iodata_to_binary(acc))}}
    end
  end

  defp safe_notify(nil, _data), do: :ok

  defp safe_notify(notify, data) when is_function(notify, 1) do
    notify.(data)
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp over_budget?(_bytes, :infinity), do: false
  defp over_budget?(bytes, max_bytes), do: bytes > max_bytes

  # The muontrap wrapper withholds further output until received bytes are
  # acknowledged (its stdio window): ack every chunk to keep output flowing.
  # report_bytes_handled/2 writes the wrapper's ack encoding to the port and
  # ignores the port-already-closed race.
  defp ack(_port, _count, :direct), do: :ok
  defp ack(port, count, :muontrap), do: MuonTrap.Port.report_bytes_handled(port, count)

  # :direct mode runs the target binary itself, so SIGKILL its pid.
  # Note: `kill -KILL os_pid` only kills the direct child, not its
  # descendants — a grandchild holding the pipe can keep running.
  defp kill_port(port, :direct) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    close_port(port)
  end

  # :muontrap mode runs the wrapper, whose whole job is to SIGTERM (then
  # SIGKILL, plus any cgroup descendants) its child when its stdin closes.
  # Closing the port *is* the group kill; SIGKILLing the wrapper itself would
  # orphan the shell and its children instead.
  defp kill_port(port, :muontrap), do: close_port(port)

  defp close_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  # Sequential tools run in the long-lived agent-loop process: `{port, ...}`
  # messages already delivered before the kill would otherwise sit in that
  # mailbox forever.
  defp drain_port(port) do
    receive do
      {^port, _} -> drain_port(port)
    after
      0 -> :ok
    end
  end

  # Command output ends up in LLM request JSON, which requires valid UTF-8.
  defp scrub(out), do: Catalyst.Tools.Truncate.scrub_utf8(out)
end
