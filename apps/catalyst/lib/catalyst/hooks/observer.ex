defmodule Catalyst.Hooks.Observer do
  @moduledoc """
  PubSub-backed process for one asynchronous event observer.

  Each callback owns one mailbox. Slow or failed observer code therefore
  affects only that observer, never the session or agent loop that broadcasts
  the event. The runtime registry remains the source of truth: a subscriber
  exits before invoking its callback when its contribution has been purged.
  """

  require Logger

  alias Catalyst.Runtime.Registry, as: Runtime

  @topic "catalyst:hook-events"

  @doc false
  @spec start(map()) :: {:ok, pid()} | {:error, term()}
  def start(entry) do
    parent = self()

    with {:ok, pid} <-
           Task.Supervisor.start_child(Catalyst.TaskSupervisor, fn -> run(entry, parent) end),
         :ok <- await_subscription(pid) do
      {:ok, pid}
    end
  end

  @doc false
  @spec stop([pid()]) :: :ok
  def stop(observers) do
    Enum.each(observers, &send(&1, :stop))
    :ok
  end

  @doc false
  @spec broadcast(term(), term()) :: :ok
  def broadcast(session_key, event) do
    Phoenix.PubSub.broadcast(
      Catalyst.PubSub,
      @topic,
      {:catalyst_hook_event, session_key, event}
    )
  end

  @doc false
  @spec await(non_neg_integer(), timeout()) :: :ok
  def await(0, _timeout), do: :ok

  def await(count, timeout) do
    ref = make_ref()
    :ok = Phoenix.PubSub.broadcast(Catalyst.PubSub, @topic, {:catalyst_hook_barrier, self(), ref})
    collect_acks(ref, count, System.monotonic_time(:millisecond) + timeout)
  end

  defp run(entry, parent) do
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, @topic)
    send(parent, {:hook_observer_ready, self()})
    loop(entry)
  end

  defp await_subscription(pid) do
    receive do
      {:hook_observer_ready, ^pid} -> :ok
    after
      1_000 -> {:error, :observer_start_timeout}
    end
  end

  defp loop(entry) do
    receive do
      {:catalyst_hook_event, _session_key, event} ->
        case current?(entry) do
          true ->
            invoke(entry, event)
            loop(entry)

          false ->
            :ok
        end

      {:catalyst_hook_barrier, caller, ref} ->
        send(caller, {:hook_observer_ack, ref, self()})
        loop(entry)

      :stop ->
        :ok
    end
  end

  defp current?(entry) do
    case Runtime.fetch(:hook, {:event, entry.seq}) do
      {:ok, %{seq: seq}, owner} -> seq == entry.seq and owner == entry.owner
      :error -> false
    end
  end

  defp invoke(entry, event) do
    entry.fun.(event)
  catch
    kind, reason ->
      Logger.warning(
        "[hooks] event/#{entry.id} #{kind}: #{Exception.format_banner(kind, reason)}"
      )
  end

  defp collect_acks(_ref, 0, _deadline), do: :ok

  defp collect_acks(ref, remaining, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:hook_observer_ack, ^ref, _observer} ->
        collect_acks(ref, remaining - 1, deadline)
    after
      timeout -> :ok
    end
  end
end
