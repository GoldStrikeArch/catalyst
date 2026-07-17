defmodule Catalyst.Hooks.ObserverDispatcher do
  @moduledoc """
  Ordered, bounded delivery for read-only agent-event observers.

  Each session has at most `:hook_observer_queue_limit` accepted events
  (default 256), counting its active event and queue. Events for one session
  run in notification order; different sessions run concurrently. Each
  observer callback runs in one supervised process under the normal hook
  deadline, without an additional per-event task or ownership watchdog.

  Stream update events are lossy under overload. Structural lifecycle events
  are not: they replace an older queued update when possible, or backpressure
  that session's producer until capacity becomes available. Admission and
  enqueue happen in the same GenServer call, so a killed notifier cannot strand
  a reservation that was never queued.
  """

  use GenServer
  require Logger

  alias Catalyst.Agent.Event

  @default_queue_limit 256

  @type session_key :: term()
  @type enqueue_result :: :ok | {:dropped, :queue_full | :dispatcher_unavailable}

  @type queued_event :: %{event: term(), entries: [map()]}
  @type waiting_event :: %{from: GenServer.from(), event: queued_event()}

  @doc "Start the singleton observer dispatcher."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Admit an event for ordered asynchronous delivery.

  Update events return `{:dropped, :queue_full}` when saturated. Structural
  events wait for a slot instead, so completion notifications are never lost.
  """
  @spec enqueue(session_key(), term(), [map()]) :: enqueue_result()
  def enqueue(_session_key, _event, []), do: :ok

  def enqueue(session_key, event, entries) do
    GenServer.call(__MODULE__, {:enqueue, session_key, event, entries}, :infinity)
  catch
    :exit, _reason -> {:dropped, :dispatcher_unavailable}
  end

  @doc "Wait until all events accepted for `session_key` have finished."
  @spec await_idle(session_key(), timeout()) :: :ok
  def await_idle(session_key, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:await_idle, session_key}, timeout)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{sessions: %{}, refs: %{}}}
  end

  @impl true
  def handle_call({:enqueue, session_key, event, entries}, from, state) do
    queued = %{event: event, entries: entries}

    case admit(state, session_key, queued, from) do
      {:reply, result, state} -> {:reply, result, state}
      {:wait, state} -> {:noreply, state}
    end
  end

  def handle_call({:await_idle, session_key}, from, state) do
    case Map.fetch(state.sessions, session_key) do
      :error ->
        {:reply, :ok, state}

      {:ok, session} ->
        session = %{session | idle_waiters: [from | session.idle_waiters]}
        {:noreply, put_session(state, session_key, session)}
    end
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    case Map.fetch(state.refs, ref) do
      {:ok, session_key} ->
        handler = state.sessions[session_key].active.handler
        Process.demonitor(ref, [:flush])
        cancel_timer(handler.timer)
        {:noreply, finish_handler(state, session_key, ref)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.refs, ref) do
      {:ok, session_key} ->
        handler = state.sessions[session_key].active.handler
        cancel_timer(handler.timer)
        log_handler_exit(handler.entry, reason)
        {:noreply, finish_handler(state, session_key, ref)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:observer_timeout, session_key, token}, state) do
    case get_in(state, [:sessions, session_key, :active, :handler]) do
      %{token: ^token} = handler ->
        Process.exit(handler.pid, :kill)
        Process.demonitor(handler.ref, [:flush])

        Logger.warning(
          "[hooks] #{handler.entry.point}/#{handler.entry.id} timed out after " <>
            "#{handler_timeout()}ms — killed and skipped"
        )

        {:noreply, finish_handler(state, session_key, handler.ref)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp admit(state, session_key, queued, from) do
    case Map.fetch(state.sessions, session_key) do
      :error ->
        session = new_session(queued)
        {:reply, :ok, state |> put_session(session_key, session) |> start_handler(session_key)}

      {:ok, session} ->
        case session.pending < queue_limit() do
          true ->
            session = enqueue_event(session, queued)
            {:reply, :ok, put_session(state, session_key, session)}

          false ->
            admit_at_capacity(state, session_key, session, queued, from)
        end
    end
  end

  defp admit_at_capacity(state, session_key, session, queued, from) do
    case update_event?(queued.event) do
      true ->
        log_dropped(session_key, session.dropped + 1)
        session = %{session | dropped: session.dropped + 1}
        {:reply, {:dropped, :queue_full}, put_session(state, session_key, session)}

      false ->
        admit_structural(state, session_key, session, queued, from)
    end
  end

  defp admit_structural(state, session_key, session, queued, from) do
    case evict_queued_update(session.queue) do
      {:ok, queue} ->
        Logger.warning(
          "[hooks] observer queue full for #{inspect(session_key)}; " <>
            "evicted a queued update to preserve a lifecycle event"
        )

        session = %{session | queue: :queue.in(queued, queue), dropped: session.dropped + 1}
        {:reply, :ok, put_session(state, session_key, session)}

      :error ->
        waiting = :queue.in(%{from: from, event: queued}, session.waiting)
        {:wait, put_session(state, session_key, %{session | waiting: waiting})}
    end
  end

  defp new_session(queued) do
    %{
      active: %{event: queued.event, remaining: queued.entries, handler: nil},
      queue: :queue.new(),
      waiting: :queue.new(),
      idle_waiters: [],
      pending: 1,
      dropped: 0
    }
  end

  defp enqueue_event(session, queued) do
    %{session | queue: :queue.in(queued, session.queue), pending: session.pending + 1}
  end

  defp start_handler(state, session_key) do
    case get_in(state, [:sessions, session_key, :active]) do
      %{handler: nil, remaining: [entry | remaining]} ->
        start_handler_task(state, session_key, entry, remaining)

      %{handler: nil, remaining: []} ->
        finish_event(state, session_key)

      _active_or_missing ->
        state
    end
  end

  defp start_handler_task(state, session_key, entry, remaining) do
    event = state.sessions[session_key].active.event
    task = async_handler(fn -> entry.fun.(event) end)
    token = make_ref()
    timer = Process.send_after(self(), {:observer_timeout, session_key, token}, handler_timeout())
    handler = %{entry: entry, pid: task.pid, ref: task.ref, timer: timer, token: token}

    state
    |> put_in([:sessions, session_key, :active], %{
      state.sessions[session_key].active
      | remaining: remaining,
        handler: handler
    })
    |> put_in([:refs, task.ref], session_key)
  end

  defp finish_handler(state, session_key, ref) do
    state
    |> update_in([:refs], &Map.delete(&1, ref))
    |> put_in([:sessions, session_key, :active, :handler], nil)
    |> start_handler(session_key)
  end

  defp finish_event(state, session_key) do
    session = state.sessions[session_key]
    session = %{session | active: nil, pending: session.pending - 1}
    {session, replies} = admit_waiting(session)
    Enum.each(replies, &GenServer.reply(&1, :ok))

    case :queue.out(session.queue) do
      {{:value, queued}, queue} ->
        active = %{event: queued.event, remaining: queued.entries, handler: nil}
        session = %{session | active: active, queue: queue}
        state |> put_session(session_key, session) |> start_handler(session_key)

      {:empty, _queue} ->
        finish_session(state, session_key, session)
    end
  end

  defp admit_waiting(session) do
    case {session.pending < queue_limit(), :queue.out(session.waiting)} do
      {true, {{:value, waiting}, rest}} ->
        session = %{
          session
          | queue: :queue.in(waiting.event, session.queue),
            waiting: rest,
            pending: session.pending + 1
        }

        {session, replies} = admit_waiting(session)
        {session, [waiting.from | replies]}

      _full_or_empty ->
        {session, []}
    end
  end

  defp finish_session(state, session_key, %{pending: 0, waiting: waiting} = session) do
    case :queue.is_empty(waiting) do
      true ->
        Enum.each(session.idle_waiters, &GenServer.reply(&1, :ok))
        %{state | sessions: Map.delete(state.sessions, session_key)}

      false ->
        put_session(state, session_key, session)
    end
  end

  defp put_session(state, session_key, session) do
    %{state | sessions: Map.put(state.sessions, session_key, session)}
  end

  defp async_handler(fun) do
    task =
      case Process.whereis(Catalyst.TaskSupervisor) do
        nil -> Task.async(fun)
        supervisor -> Task.Supervisor.async(supervisor, fun)
      end

    task
  catch
    :exit, _reason -> Task.async(fun)
  end

  defp evict_queued_update(queue) do
    queue
    |> :queue.to_list()
    |> remove_first_update([])
  end

  defp remove_first_update([], _prefix), do: :error

  defp remove_first_update([queued | rest], prefix) do
    case update_event?(queued.event) do
      true -> {:ok, :queue.from_list(Enum.reverse(prefix, rest))}
      false -> remove_first_update(rest, [queued | prefix])
    end
  end

  defp update_event?(%Event.MessageUpdate{}), do: true
  defp update_event?(%Event.ToolExecutionUpdate{}), do: true
  defp update_event?(_event), do: false

  defp log_dropped(session_key, dropped) do
    case dropped == 1 or power_of_two?(dropped) do
      true ->
        Logger.warning(
          "[hooks] observer queue full for #{inspect(session_key)}; " <>
            "dropped newest update (#{dropped} dropped)"
        )

      false ->
        :ok
    end
  end

  defp log_handler_exit(_entry, :normal), do: :ok

  defp log_handler_exit(entry, reason) do
    Logger.warning("[hooks] #{entry.point}/#{entry.id} exited: #{inspect(reason)}")
  end

  defp cancel_timer(timer) do
    _cancelled = Process.cancel_timer(timer, async: true, info: false)
    :ok
  end

  defp handler_timeout do
    Application.get_env(:catalyst, :hook_handler_timeout, 10_000)
  end

  defp queue_limit do
    case Application.get_env(:catalyst, :hook_observer_queue_limit, @default_queue_limit) do
      limit when is_integer(limit) and limit > 0 -> limit
      _invalid -> @default_queue_limit
    end
  end

  defp power_of_two?(number), do: Bitwise.band(number, number - 1) == 0
end
