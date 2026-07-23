defmodule Catalyst.Tasks do
  @moduledoc """
  Small, shared helpers for supervised task work.

  Catalyst normally runs tasks under `Catalyst.TaskSupervisor`. The helpers
  retain a plain `Task` fallback for focused tests, scripts, and shutdown races
  where the application supervisor is not running.
  """

  @type await_result(value) :: {:ok, value} | {:exit, term()} | :timeout

  @doc "Start an awaitable task, supervised when Catalyst is running."
  @spec async((-> value)) :: Task.t() when value: term()
  def async(fun) when is_function(fun, 0) do
    owner = self()
    owned_fun = fn -> run_owned(owner, fun) end

    case Process.whereis(Catalyst.TaskSupervisor) do
      nil -> async_unlinked(owned_fun, owner)
      supervisor -> start_supervised(supervisor, owned_fun, owner)
    end
  end

  @doc "Start caller-owned work under a specific task supervisor, with the same safe fallback."
  @spec async_on(GenServer.server(), (-> value)) :: Task.t() when value: term()
  def async_on(supervisor, fun) when is_function(fun, 0) do
    owner = self()
    start_supervised(supervisor, fn -> run_owned(owner, fun) end, owner)
  end

  @doc "Yield an awaitable task, brutally stopping it after `timeout`."
  @spec await(Task.t(), timeout()) :: await_result(term())
  def await(task, timeout) do
    case Task.yield(task, timeout) do
      {:ok, value} ->
        {:ok, value}

      {:exit, reason} ->
        {:exit, reason}

      nil ->
        case Task.shutdown(task, :brutal_kill) do
          {:ok, value} -> {:ok, value}
          {:exit, reason} -> {:exit, reason}
          nil -> :timeout
        end
    end
  end

  @doc "Current monotonic time in milliseconds, for deadlines and idle clocks."
  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @doc """
  Start fire-and-forget work without crashing when the shared supervisor is
  absent or disappears during a shutdown race.
  """
  @spec start_background((-> term())) :: {:ok, pid()} | {:error, term()}
  def start_background(fun) when is_function(fun, 0) do
    case Process.whereis(Catalyst.TaskSupervisor) do
      nil -> Task.start(fun)
      _pid -> Task.Supervisor.start_child(Catalyst.TaskSupervisor, fun)
    end
  catch
    :exit, reason -> {:error, reason}
  end

  # Task.async/1 links before the caller can unlink, so a fast failure can
  # still take the caller down. Hold the child behind a private handshake,
  # remove the link, then release it; the Task monitor/reply protocol remains
  # intact for yield/shutdown.
  defp start_supervised(supervisor, fun, owner) do
    Task.Supervisor.async_nolink(supervisor, fun)
  catch
    :exit, _reason -> async_unlinked(fun, owner)
  end

  defp async_unlinked(fun, owner) do
    gate = make_ref()

    task =
      Task.async(fn ->
        owner_ref = Process.monitor(owner)

        receive do
          {^gate, :run} -> fun.()
          {:DOWN, ^owner_ref, :process, ^owner, _reason} -> exit(:kill)
        end
      end)

    Process.unlink(task.pid)
    send(task.pid, {gate, :run})
    task
  end

  # async_nolink isolates task failures, but by itself lets work outlive a
  # killed caller. A tiny watchdog gives the worker caller ownership without
  # reintroducing a failure link: caller DOWN brutally stops the worker, while
  # worker DOWN retires the watchdog.
  defp run_owned(owner, fun) do
    worker = self()
    ready = make_ref()
    _watchdog = spawn(fn -> watch_owner(owner, worker, ready) end)

    receive do
      {^ready, :watching} -> fun.()
    end
  end

  defp watch_owner(owner, worker, ready) do
    owner_ref = Process.monitor(owner)
    worker_ref = Process.monitor(worker)
    send(worker, {ready, :watching})

    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
    end
  end
end
