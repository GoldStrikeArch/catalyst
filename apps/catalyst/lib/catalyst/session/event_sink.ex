defmodule Catalyst.Session.EventSink do
  @moduledoc """
  Delivers run events to their side-effect boundaries.

  Ordinary events are observed before they enter the session mailbox. Durable
  events are broadcast by the session only after a successful append. Observer
  callbacks run in their own PubSub subscriber processes, outside the session.
  """

  alias Catalyst.Agent.Event
  alias Catalyst.{Debug, Hooks}

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
  Persist a run event synchronously.

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
  Hand a successfully persisted event to debug logging and observers.

  PubSub delivery is acknowledged before returning; filesystem logging and
  observer callbacks run outside the session process.
  """
  @spec committed(Event.t(), term()) :: :ok
  def committed(event, session_key) do
    _debug_task = Debug.log_event_async(debug_session_id(session_key), event)
    Hooks.notify(event, session_key)
  end

  @doc "Broadcast observation of a host-synthesized event without running callbacks inline."
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

  defp debug_session_id(session_id) when is_binary(session_id), do: session_id
  defp debug_session_id(_session_key), do: nil
end
