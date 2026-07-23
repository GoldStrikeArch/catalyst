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
  @max_receive_timeout 4_294_967_295
  @owner_shutdown_grace 1_000

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
  output), and `:on_output` (a crash-isolated function called for each chunk).
  stderr is merged into stdout.

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
        case status in ok_statuses do
          true -> res
          false -> raise "#{label} error (status #{status}): #{String.slice(out, 0, 200)}"
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
  `:env`, `:max_output_bytes` (default `bash_max_output_bytes/0`), and
  `:on_output` (a crash-isolated function called for each chunk).
  Returns `{:ok, %{out, status}}` — with `truncated: true` when the output
  cap killed the command early — or `{:error, {:timeout, partial_out}}`, so
  partial output is preserved on timeout.

  The command runs under the muontrap wrapper so that hitting the timeout or
  the output cap kills the whole child process tree: closing the wrapper's
  port makes it SIGTERM (then SIGKILL) its child, which a plain port close
  would leave running. A dedicated supervised task owns the linked port;
  chunk callbacks and accumulation stay in the caller, and caller-side
  failures always stop the owner before returning `{:error, exception}`.
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

    try do
      run(MuonTrap.muontrap_path(), args, opts, :muontrap)
    rescue
      # narrow exception handling: only rescue ArgumentError from port boundary
      # (e.g. malformed PORT in env passing through to System.cmd internally)
      e in ArgumentError -> {:error, e}
    end
  end

  defp run(path, args, opts, mode) do
    with :ok <- validate_options(opts) do
      do_run(path, args, opts, mode)
    end
  end

  defp do_run(path, args, opts, mode) do
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

    caller = self()
    token = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout

    task =
      Catalyst.Tasks.async(fn ->
        port_owner(caller, token, path, port_opts, mode)
      end)

    try do
      collect_loop(
        task,
        token,
        [],
        0,
        deadline,
        max_bytes,
        notify: Keyword.get(opts, :on_output)
      )
    after
      ensure_owner_stopped(task, token)
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp validate_options(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         :ok <- validate_timeout(Keyword.get(opts, :timeout, @default_timeout)),
         :ok <- validate_max_output(Keyword.get(opts, :max_output_bytes, :infinity)),
         :ok <- validate_notify(Keyword.get(opts, :on_output)) do
      :ok
    else
      false -> {:error, {:invalid_options, opts}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_options(opts), do: {:error, {:invalid_options, opts}}

  defp validate_timeout(timeout)
       when is_integer(timeout) and timeout >= 0 and timeout <= @max_receive_timeout,
       do: :ok

  defp validate_timeout(timeout), do: {:error, {:invalid_option, :timeout, timeout}}

  defp validate_max_output(:infinity), do: :ok
  defp validate_max_output(bytes) when is_integer(bytes) and bytes >= 0, do: :ok
  defp validate_max_output(bytes), do: {:error, {:invalid_option, :max_output_bytes, bytes}}

  defp validate_notify(nil), do: :ok
  defp validate_notify(notify) when is_function(notify, 1), do: :ok
  defp validate_notify(notify), do: {:error, {:invalid_option, :on_output, notify}}

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
  defp collect_loop(task, token, acc, bytes, deadline, max_bytes, opts) do
    owner = task.pid
    task_ref = task.ref
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case remaining do
      0 ->
        stop_owner(task, token)
        {:error, {:timeout, scrub(acc_to_binary(acc))}}

      _positive ->
        receive do
          {^token, ^owner, {:data, data}} ->
            collect_data(task, token, data, acc, bytes, deadline, max_bytes, opts)

          {^task_ref, {:status, status}} ->
            finish_owner(task, token)
            {:ok, %{out: scrub(acc_to_binary(acc)), status: status}}

          {^task_ref, {:error, reason}} ->
            finish_owner(task, token)
            {:error, reason}

          {^task_ref, {:status_lost, reason}} ->
            finish_owner(task, token)

            # The ack write raced the wrapper's exit (see port_loop): output is
            # complete but the exit status is unrecoverable. Mirror the owner
            # DOWN fallback below — with output in hand, treat it as a success.
            case acc do
              [] -> {:error, {:port_exit, reason}}
              _ -> {:ok, %{out: scrub(acc_to_binary(acc)), status: 0}}
            end

          {:DOWN, ^task_ref, :process, ^owner, reason} ->
            drain_owner_messages(token, owner)

            # If the process exited before we could read status, but we have output,
            # treat it as ok if it's likely just a race with status.
            case acc do
              [] -> {:error, {:port_owner_exit, reason}}
              _ -> {:ok, %{out: scrub(acc_to_binary(acc)), status: 0}}
            end
        after
          remaining ->
            stop_owner(task, token)
            {:error, {:timeout, scrub(acc_to_binary(acc))}}
        end
    end
  end

  defp collect_data(task, token, data, acc, bytes, deadline, max_bytes, opts) do
    case over_budget?(bytes + byte_size(data), max_bytes) do
      true ->
        stop_owner(task, token)
        {:ok, %{out: scrub(acc_to_binary([data | acc])), status: 0, truncated: true}}

      false ->
        safe_notify(opts[:notify], data)
        send(task.pid, {token, self(), {:continue, byte_size(data)}})

        collect_loop(
          task,
          token,
          [data | acc],
          bytes + byte_size(data),
          deadline,
          max_bytes,
          opts
        )
    end
  end

  # The disposable task is the only process linked to the port. It relays one
  # chunk at a time and waits for the caller's decision, preserving output
  # order while keeping callback execution and accumulation in the caller.
  defp port_owner(caller, token, path, port_opts, mode) do
    Process.flag(:trap_exit, true)
    port = Port.open({:spawn_executable, path}, port_opts)

    try do
      port_loop(port, caller, token, mode)
    after
      close_port(port)
    end
  rescue
    error -> {:error, error}
  end

  defp port_loop(port, caller, token, mode) do
    receive do
      {^token, ^caller, :stop} ->
        kill_port(port, mode)
        :stopped

      {^port, {:data, data}} ->
        send(caller, {token, self(), {:data, data}})
        await_caller(port, caller, token, mode)

      {^port, {:exit_status, status}} ->
        {:status, status}

      {:EXIT, ^port, :epipe} when mode == :muontrap ->
        # In :muontrap mode the only port writes are the ack bytes for
        # already-received chunks (see ack/3). :epipe on that write means the
        # wrapper exited after forwarding everything but before the port
        # delivered its exit_status — the ack raced the exit, the command did
        # not fail. Report it distinctly so collect_loop can salvage the run.
        {:status_lost, :epipe}

      {:EXIT, ^port, reason} ->
        {:error, {:port_exit, reason}}

      {:EXIT, _linked, reason} ->
        kill_port(port, mode)
        exit(reason)
    end
  end

  # Port messages are deliberately unmatched here. Selective receive leaves
  # them in their original order until the relayed chunk is acknowledged.
  defp await_caller(port, caller, token, mode) do
    receive do
      {^token, ^caller, {:continue, count}} ->
        ack(port, count, mode)
        port_loop(port, caller, token, mode)

      {^token, ^caller, :stop} ->
        kill_port(port, mode)
        :stopped

      {:EXIT, linked, reason} when linked != port ->
        kill_port(port, mode)
        exit(reason)
    end
  end

  defp stop_owner(task, token) do
    send(task.pid, {token, self(), :stop})
    _result = Catalyst.Tasks.await(task, @owner_shutdown_grace)
    finish_owner(task, token)
  end

  defp finish_owner(task, token) do
    Process.demonitor(task.ref, [:flush])
    drain_owner_messages(token, task.pid)
    drain_task_replies(task.ref)
  end

  defp ensure_owner_stopped(task, token) do
    case Process.alive?(task.pid) do
      true -> stop_live_owner(task, token)
      false -> :ok
    end

    finish_owner(task, token)
  end

  defp stop_live_owner(task, token) do
    monitor = Process.monitor(task.pid)
    send(task.pid, {token, self(), :stop})

    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    after
      @owner_shutdown_grace ->
        Process.exit(task.pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
        end
    end
  end

  # A Task reply or DOWN is an ordering fence: the same owner sent every relay
  # before terminating, so no matching protocol message can arrive later.
  defp drain_owner_messages(token, owner) do
    receive do
      {^token, ^owner, _message} -> drain_owner_messages(token, owner)
    after
      0 -> :ok
    end
  end

  defp drain_task_replies(ref) do
    receive do
      {^ref, _result} -> drain_task_replies(ref)
      {:DOWN, ^ref, :process, _pid, _reason} -> drain_task_replies(ref)
    after
      0 -> :ok
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

  defp safe_notify(_invalid, _data), do: :ok

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

  # Command output ends up in LLM request JSON, which requires valid UTF-8.
  defp acc_to_binary(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp scrub(out), do: Catalyst.Tools.Truncate.scrub_utf8(out)
end
