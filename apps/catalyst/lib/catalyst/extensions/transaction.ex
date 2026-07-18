defmodule Catalyst.Extensions.Transaction do
  @moduledoc """
  Serializes extension compilation and lifecycle transactions.

  Work runs in a supervised caller-independent task. Nested transactions are
  re-entrant in that task, allowing install operations to compose file writes,
  compilation, and commit under one lock. Each outer transaction captures the
  current `Catalyst.Extensions` server and runtime generation; nested API calls
  remain pinned to that generation instead of accidentally mutating a server
  that restarted while the transaction was in flight. Monitored boot work can
  use the inline form so the boot worker itself owns the lock and generation.

  Extension API dispatch uses a separate generation gate. That gate serializes
  an in-flight registration with generation publication and prior-owner purge,
  without deadlocking setup callbacks that already run beneath the load lock in
  their own monitored processes. Runtime replacement takes the load lock before
  this gate, matching the load/setup → dispatch order.
  """

  @load_lock {Catalyst.Extensions, :load_lock}
  @generation_gate {Catalyst.Extensions, :generation_gate}
  @context_key {Catalyst.Extensions, :load_context}
  @generation_context_key {Catalyst.Extensions, :generation_context}
  @server_key {Catalyst.Extensions, :load_server}
  @generation_key {Catalyst.Extensions, :load_generation}

  @doc "Run a zero-arity function under the global extension load lock."
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
    run_inline(
      Process.whereis(Catalyst.Extensions) || Catalyst.Extensions,
      Catalyst.Extensions.generation_token(),
      fun
    )
  end

  @doc false
  @spec run_inline(GenServer.server(), reference() | nil, (-> result)) :: result
        when result: term()
  def run_inline(server, generation, fun) when is_function(fun, 0) do
    case Process.get(@context_key, false) do
      true -> fun.()
      false -> with_lock(server, generation, fun)
    end
  end

  @doc false
  @spec with_generation_gate((-> result)) :: result when result: term()
  def with_generation_gate(fun) when is_function(fun, 0) do
    case Process.get(@generation_context_key, false) do
      true -> fun.()
      false -> generation_gate(fun)
    end
  end

  @doc false
  @spec server() :: GenServer.server()
  def server do
    Process.get(@server_key, Process.whereis(Catalyst.Extensions) || Catalyst.Extensions)
  end

  @doc false
  @spec generation() :: reference() | nil
  def generation, do: Process.get(@generation_key, Catalyst.Extensions.generation_token())

  defp run_task(fun) do
    server = Process.whereis(Catalyst.Extensions) || Catalyst.Extensions
    generation = Catalyst.Extensions.generation_token()

    case start_task(server, generation, fun) do
      {:ok, task} -> await_task(task)
      :error -> with_lock(server, generation, fun)
    end
  end

  defp start_task(server, generation, fun) do
    task =
      Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
        capture_outcome(fn -> with_lock(server, generation, fun) end)
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

  defp with_lock(server, generation, fun) do
    :global.trans(
      {@load_lock, self()},
      fn ->
        Process.put(@context_key, true)
        Process.put(@server_key, server)
        Process.put(@generation_key, generation)

        try do
          fun.()
        after
          Process.delete(@context_key)
          Process.delete(@server_key)
          Process.delete(@generation_key)
        end
      end,
      [node()],
      :infinity
    )
  end

  defp generation_gate(fun) do
    :global.trans(
      {@generation_gate, self()},
      fn ->
        Process.put(@generation_context_key, true)

        try do
          fun.()
        after
          Process.delete(@generation_context_key)
        end
      end,
      [node()],
      :infinity
    )
  end
end
