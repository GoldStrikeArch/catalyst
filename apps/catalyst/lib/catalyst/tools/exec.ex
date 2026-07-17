defmodule Catalyst.Tools.Exec do
  @moduledoc """
  Two shell-out modes (PI's tool execution backends):

    * `collect/3` — run a binary to completion via a `Port`, capture stdout
      (stderr merged), parse after exit. Used by ripgrep/fd/sd/ast-grep.
    * `bash/2` — run a shell command via MuonTrap so a timeout or an aborted
      run kills the whole child process group, not just the shell. Used by bash.
  """

  @default_timeout 120_000

  @type collect_result :: {:ok, %{out: String.t(), status: integer()}} | {:error, term()}

  @doc """
  Run `path` with `args` to completion. Options: `:cwd`, `:timeout` (ms),
  `:env` (list of `{name, value}`). stderr is merged into stdout.
  """
  @spec collect(String.t(), [String.t()], keyword()) :: collect_result()
  def collect(path, args, opts \\ []) do
    cwd = Keyword.get(opts, :cwd) || File.cwd!()
    timeout = Keyword.get(opts, :timeout, @default_timeout)

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
      collect_loop(port, [], timeout)
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

  defp collect_loop(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_loop(port, [acc, data], timeout)

      {^port, {:exit_status, status}} ->
        {:ok, %{out: IO.iodata_to_binary(acc), status: status}}
    after
      timeout ->
        kill_port(port)
        {:error, :timeout}
    end
  end

  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
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

  @doc """
  Run a shell command. Options: `:cwd`, `:timeout` (ms, default none),
  `:env`. Returns `{:ok, %{out, status}}` or `{:error, :timeout}`. On timeout the
  process group is killed via MuonTrap.
  """
  @spec bash(String.t(), keyword()) :: collect_result()
  def bash(command, opts \\ []) do
    cwd = Keyword.get(opts, :cwd) || File.cwd!()
    timeout = Keyword.get(opts, :timeout)

    cmd_opts = [cd: cwd, stderr_to_stdout: true] ++ muontrap_env(opts)

    task = Task.async(fn -> MuonTrap.cmd("sh", ["-c", command], cmd_opts) end)

    result =
      if timeout do
        Task.yield(task, timeout) || :timeout
      else
        {:ok, Task.await(task, :infinity)}
      end

    case result do
      {:ok, {out, status}} ->
        {:ok, %{out: out, status: status}}

      {:exit, reason} ->
        {:error, reason}

      :timeout ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp muontrap_env(opts) do
    case Keyword.get(opts, :env) do
      nil -> []
      env -> [env: Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)]
    end
  end
end
