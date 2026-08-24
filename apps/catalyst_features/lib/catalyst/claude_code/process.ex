defmodule Catalyst.ClaudeCode.Process do
  @moduledoc """
  Bounded macOS process runner for one direct Claude print-mode invocation.
  """

  alias Catalyst.ClaudeCode.Command

  @max_line_bytes 2 * 1024 * 1024
  @max_output_bytes 32 * 1024 * 1024
  @default_timeout 30 * 60 * 1_000
  @termination_grace 1_000

  @doc """
  Run `command`, folding each output line through `handle_line`.

  stderr is merged for the initial local experiment; non-JSON diagnostics are
  retained by the workflow mapper and bounded by the same total-output limit.
  """
  @spec run(
          Command.t(),
          Path.t(),
          term(),
          (binary(), term() -> {:ok, term()} | {:error, term()}),
          keyword()
        ) ::
          {:ok, term(), non_neg_integer()} | {:error, term()}
  def run(%Command{} = command, cwd, initial, handle_line, opts \\ [])
      when is_function(handle_line, 2) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, port} <- open_port(command, cwd) do
      try do
        receive_loop(port, initial, handle_line, deadline, 0)
      after
        close_port(port)
      end
    end
  end

  defp receive_loop(port, state, handle_line, deadline, bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, line}}} ->
        next_bytes = bytes + byte_size(line)

        case next_bytes <= @max_output_bytes do
          true ->
            with {:ok, state} <- handle_line.(line, state) do
              receive_loop(port, state, handle_line, deadline, next_bytes)
            end

          false ->
            terminate(port)
            {:error, :output_too_large}
        end

      {^port, {:data, {:noeol, _partial}}} ->
        terminate(port)
        {:error, :line_too_large}

      {^port, {:exit_status, status}} ->
        {:ok, state, status}

      {:EXIT, ^port, reason} ->
        {:error, {:port_exit, reason}}
    after
      remaining ->
        terminate(port)
        {:error, :timeout}
    end
  end

  defp open_port(command, cwd) do
    options = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      :hide,
      {:line, @max_line_bytes},
      {:args, command.args},
      {:cd, cwd}
    ]

    {:ok, Port.open({:spawn_executable, command.executable}, options)}
  rescue
    error in ArgumentError -> {:error, {:process_launch, error}}
  end

  defp terminate(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        _result = System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
        await_exit(port, pid)

      _missing ->
        close_port(port)
    end
  end

  defp await_exit(port, pid) do
    receive do
      {^port, {:exit_status, _status}} ->
        :ok
    after
      @termination_grace ->
        _result = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        close_port(port)
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
