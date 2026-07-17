defmodule Catalyst.Tools.Exec do
  @moduledoc """
  Two shell-out modes (PI's tool execution backends):

    * `collect/3` — run a binary to completion via a `Port`, capture stdout
      (stderr merged), parse after exit. Used by ripgrep/fd/sd/ast-grep.
    * `bash/2` — run a shell command via MuonTrap so a timeout or an aborted
      run kills the whole child process group, not just the shell. Used by bash.
  """

  @default_timeout 120_000

  @type collect_result ::
          {:ok, %{:out => String.t(), :status => integer(), optional(:truncated) => true}}
          | {:error, term()}

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
      collect_loop(port, [], 0, deadline, max_bytes)
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
  # returned as a truncated success.
  defp collect_loop(port, acc, bytes, deadline, max_bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        case over_budget?(bytes + byte_size(data), max_bytes) do
          true ->
            kill_port(port)
            drain_port(port)
            {:ok, %{out: scrub(IO.iodata_to_binary([acc, data])), status: 0, truncated: true}}

          false ->
            collect_loop(port, [acc, data], bytes + byte_size(data), deadline, max_bytes)
        end

      {^port, {:exit_status, status}} ->
        {:ok, %{out: scrub(IO.iodata_to_binary(acc)), status: status}}
    after
      remaining ->
        kill_port(port)
        drain_port(port)
        {:error, :timeout}
    end
  end

  defp over_budget?(_bytes, :infinity), do: false
  defp over_budget?(bytes, max_bytes), do: bytes > max_bytes

  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        # Note: `kill -KILL os_pid` only kills the direct child, not its
        # descendants — a grandchild holding the pipe can keep running.
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

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

  @doc """
  Run a shell command. Options: `:cwd`, `:timeout` (ms, default none), `:env`.
  Returns `{:ok, %{out, status}}` or `{:error, {:timeout, partial_out}}`. The
  timeout is MuonTrap's own (SIGTERM then SIGKILL on the whole process group),
  so partial output is preserved. Runs in the calling process — a raise becomes
  `{:error, exception}` instead of killing a linked caller.
  """
  @spec bash(String.t(), keyword()) :: collect_result() | {:error, {:timeout, String.t()}}
  def bash(command, opts \\ []) do
    cwd = Keyword.get(opts, :cwd) || File.cwd!()

    cmd_opts =
      [cd: cwd, stderr_to_stdout: true] ++ timeout_opt(opts) ++ muontrap_env(opts)

    # The tool is named "bash", but on Debian-family systems `sh` is dash and
    # bashisms would fail — resolve real bash when present. A per-call
    # find_executable is a cheap PATH scan.
    shell = System.find_executable("bash") || "sh"

    case MuonTrap.cmd(shell, ["-c", command], cmd_opts) do
      {out, :timeout} -> {:error, {:timeout, scrub(out)}}
      {out, status} -> {:ok, %{out: scrub(out), status: status}}
    end
  rescue
    e -> {:error, e}
  end

  defp timeout_opt(opts) do
    case Keyword.get(opts, :timeout) do
      nil -> []
      ms -> [timeout: ms]
    end
  end

  defp muontrap_env(opts) do
    case Keyword.get(opts, :env) do
      nil -> []
      env -> [env: Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)]
    end
  end

  # Command output ends up in LLM request JSON, which requires valid UTF-8.
  defp scrub(out), do: Catalyst.Tools.Truncate.scrub_utf8(out)
end
