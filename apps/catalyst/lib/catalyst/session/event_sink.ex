defmodule Catalyst.Session.EventSink do
  @moduledoc """
  Delivers run events to their side-effect boundaries.

  Ordinary events are observed before they enter the session mailbox. Durable
  events are handed to ordered observer delivery by the session only after a
  successful append and before PubSub broadcast or the persistence reply.
  Observer callbacks still run outside the session process. Host-synthesized
  events use bounded, non-blocking dispatcher admission.
  """

  require Logger

  alias Catalyst.Agent.Event
  alias Catalyst.{Debug, Hooks}
  alias Catalyst.Hooks.ObserverDispatcher

  @committed_retry_ms 10
  @committed_deadline_ms 500

  defp committed_deadline do
    case Application.get_env(:catalyst, :event_sink_deadline_ms, @committed_deadline_ms) do
      timeout when is_integer(timeout) and timeout >= 0 -> timeout
      _invalid -> @committed_deadline_ms
    end
  end

  @type emitter :: (Event.t() -> any())

  @doc "Wrap an emitter with ordered debug logging and observer delivery."
  @spec observed(emitter(), term()) :: emitter()
  def observed(emit, session_key) when is_function(emit, 1) do
    fn event ->
      Debug.log_event(debug_session_id(session_key), event)
      Hooks.notify(event, session_key)
      emit.(event)
    end
  end

  @doc """
  Persist a run event synchronously. The session acknowledges ordered observer
  admission before this function returns.

  A failed or stale persistence request is returned unchanged and is not shown
  to observers. Observer callbacks never run in `Session.Server`.
  """
  @spec persist(GenServer.server(), reference(), Event.t()) :: :ok | {:error, term()}
  def persist(server, run_ref, event) when is_reference(run_ref) do
    case call_server(server, run_ref, event) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        error

      invalid ->
        {:error, {:invalid_persistence_reply, invalid}}
    end
  end

  @doc """
  Hand a successfully persisted event to debug logging and ordered observers.

  Queue admission is acknowledged before returning; filesystem logging and
  observer callbacks run outside the session process. A dispatcher crash after
  acknowledgement can lose queued callback work, while an ambiguous admission
  failure may cause a retry to deliver twice; observers must be duplicate-safe.
  """
  @spec committed(Event.t(), term()) :: :ok
  def committed(event, session_key) do
    _debug_task = Debug.log_event_async(debug_session_id(session_key), event)
    deadline = System.monotonic_time(:millisecond) + committed_deadline()
    await_committed_handlers(event, session_key, deadline)
  end

  @doc """
  Queue observation of a host-synthesized event without blocking its server.

  The observer cast is sent before the event is broadcast, preserving ordering
  with a subsequent run.
  """
  @spec synthetic(Event.t(), term()) :: :ok
  def synthetic(event, session_key) do
    :ok = Hooks.notify_async(event, session_key)
    :ok
  end

  defp call_server(server, run_ref, event) do
    GenServer.call(server, {:persist_run_event, run_ref, event}, :infinity)
  catch
    :exit, reason -> {:error, {:session_down, reason}}
  end

  # A committed compaction is already on disk and installed in live state, so
  # losing its observer handoff would make the event boundaries disagree.
  # Retry infrastructure availability until the configurable deadline;
  # enqueue_committed/3 never waits for callback execution or bounded queue
  # capacity.
  defp await_committed_handlers(event, session_key, deadline) do
    case remaining_ms(deadline) do
      remaining when remaining <= 0 ->
        warn_dropped_event(:registry_unavailable, event, session_key)

      _remaining ->
        case committed_handlers() do
          {:ok, entries} -> await_committed_admission(event, session_key, entries, deadline)
          {:error, :registry_unavailable} -> retry_handlers(event, session_key, deadline)
        end
    end
  end

  # The table owner keeps observer data alive during the registry process's
  # rebuild. Read the durable table directly: readiness gates synchronous hook
  # snapshots, but committed observer admission must not strand a session while
  # a new extension generation is still bootstrapping.
  defp committed_handlers, do: Hooks.fetch_handlers(:event)

  defp retry_handlers(event, session_key, deadline) do
    Process.sleep(retry_delay(deadline))
    await_committed_handlers(event, session_key, deadline)
  end

  defp await_committed_admission(event, session_key, entries, deadline) do
    case remaining_ms(deadline) do
      remaining when remaining <= 0 ->
        warn_dropped_event(:dispatcher_unavailable, event, session_key)

      remaining ->
        case ObserverDispatcher.enqueue_committed(
               session_key || self(),
               event,
               entries,
               min(@committed_retry_ms, remaining)
             ) do
          :ok ->
            :ok

          {:error, :dispatcher_unavailable} ->
            Process.sleep(retry_delay(deadline))
            await_committed_admission(event, session_key, entries, deadline)
        end
    end
  end

  defp remaining_ms(deadline), do: deadline - System.monotonic_time(:millisecond)
  defp retry_delay(deadline), do: max(1, min(@committed_retry_ms, remaining_ms(deadline)))

  defp warn_dropped_event(reason, event, session_key) do
    Logger.warning(
      "EventSink dropped committed event due to #{reason} after deadline. " <>
        "Event: #{inspect(event)}, Session: #{inspect(session_key)}"
    )

    :ok
  end

  defp debug_session_id(session_id) when is_binary(session_id), do: session_id
  defp debug_session_id(_session_key), do: nil
end
