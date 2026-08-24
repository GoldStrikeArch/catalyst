defmodule Catalyst.Extensions.Transaction do
  @moduledoc """
  Serializes extension compilation and lifecycle transactions.

  Nested transactions are re-entrant, allowing install operations to compose
  file writes, compilation, and projection rebuild under one global lock. The
  extension sources are durable state; a coordinator restart rebuilds their
  runtime projection rather than preserving an in-flight generation.
  """

  @load_lock {Catalyst.Extensions, :load_lock}
  @context_key {Catalyst.Extensions, :load_context}
  @server_key {Catalyst.Extensions, :load_server}

  @doc """
  Run a zero-arity function under the global extension load lock.

  The outer transaction is detached from its caller so a caller exit cannot
  interrupt an already committed extension setup. Nested transactions remain
  in the same task and reuse the lock.
  """
  @spec run((-> result)) :: result when result: term()
  def run(fun) when is_function(fun, 0) do
    case Process.get(@context_key, false) do
      true -> fun.()
      false -> run_task(fun)
    end
  end

  @doc false
  @spec run_inline((-> result)) :: result when result: term()
  def run_inline(fun) when is_function(fun, 0) do
    case Process.get(@context_key, false) do
      true -> fun.()
      false -> with_lock(current_server(), fun)
    end
  end

  @doc false
  @spec server() :: GenServer.server()
  def server do
    Process.get(@server_key, current_server())
  end

  defp run_task(fun) do
    server = current_server()

    case start_task(server, fun) do
      {:ok, task} -> await_task(task)
      :error -> with_lock(server, fun)
    end
  end

  defp start_task(server, fun) do
    task =
      Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
        capture_outcome(fn -> with_lock(server, fun) end)
      end)

    {:ok, task}
  catch
    :exit, _reason -> :error
  end

  defp await_task(task) do
    case Task.yield(task, :infinity) do
      {:ok, {:return, result}} -> result
      {:ok, {:raised, kind, reason, stacktrace}} -> :erlang.raise(kind, reason, stacktrace)
      {:exit, reason} -> exit(reason)
    end
  end

  defp capture_outcome(fun) do
    {:return, fun.()}
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp with_lock(server, fun) do
    :global.trans(
      {@load_lock, self()},
      fn ->
        Process.put(@context_key, true)
        Process.put(@server_key, server)

        try do
          fun.()
        after
          Process.delete(@context_key)
          Process.delete(@server_key)
        end
      end,
      [node()],
      :infinity
    )
  end

  defp current_server, do: Process.whereis(Catalyst.Extensions) || Catalyst.Extensions
end
