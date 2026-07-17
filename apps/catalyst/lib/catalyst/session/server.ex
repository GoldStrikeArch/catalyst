defmodule Catalyst.Session.Server do
  @moduledoc """
  Stateful owner of one session (PI's `Agent` class).

  The single writer of the transcript, model, queues, and pending-tool state. A
  `prompt`/`continue` runs `Catalyst.Agent.Loop` in a supervised Task; the loop
  emits events back as `{:agent_event, run_ref, e}` casts, which this server folds
  into state (append on `message_end`, persist to JSONL, track pending tool calls)
  and re-broadcasts as `{:agent_event, id, e}` on `"session:<id>"` for any
  subscribers (LiveViews/CLI).

  Cancellation shuts down the active run task; its linked ports/MuonTrap daemons
  die with it, and an aborted turn is synthesized.
  """

  use GenServer

  alias Catalyst.Agent.{Event, Loop}
  alias Catalyst.Message
  alias Catalyst.Session.{Manager, Reducer, RunConfig, Snapshot, Store}

  defmodule State do
    @moduledoc false
    defstruct [
      :id,
      :cwd,
      :system_prompt,
      :model,
      :provider,
      :tools,
      :opts,
      :store,
      :run,
      # Ref identifying the CURRENT run; events from killed/finished runs that
      # are still buffered in the mailbox carry a stale ref and are dropped.
      :run_ref,
      # Whether the current run's AgentEnd was folded/broadcast — lets abort
      # tell "run finished cleanly" from "its tail events got dropped".
      agent_ended: false,
      # Transcript, stored NEWEST-FIRST so per-event appends are O(1); reversed
      # at the boundaries (Snapshot.of/1, start_run's loop context).
      messages: [],
      streaming_message: nil,
      # Streamed deltas of the in-flight assistant message, accumulated as
      # iodata so a reattaching UI can rebuild the partial bubble (Snapshot).
      streaming_text: [],
      streaming_thinking: [],
      pending_tool_calls: MapSet.new(),
      error_message: nil,
      steering: :queue.new(),
      follow_up: :queue.new(),
      # Messages handed to the run via drain_steering/drain_follow_up but not
      # yet folded back as MessageEnd events — re-queued if the run dies, so an
      # abort can't swallow a user's steering message. `{:steering | :follow_up, msg}`.
      in_flight: []
    ]
  end

  # ---- public API -----------------------------------------------------------

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: Manager.via(id))
  end

  @doc "PubSub topic for a session id."
  def topic(id), do: "session:" <> id

  @doc """
  Queue a user prompt and start a run. Returns `:ok`, `{:error, :busy}`, or
  `{:error, :no_provider | {:unknown_api, api}}` when the session has no
  resolvable provider.
  """
  def prompt(server, input), do: GenServer.call(server, {:prompt, normalize(input)})

  @doc "Continue running (no new prompt) — e.g. after steering/follow-up. Same returns as `prompt/2`."
  def continue(server), do: GenServer.call(server, :continue)

  @doc "Inject a message mid-run, applied before the next LLM call."
  def steer(server, input), do: GenServer.cast(server, {:steer, normalize(input)})

  @doc "Queue a message to run after the agent reaches a natural stop."
  def follow_up(server, input), do: GenServer.cast(server, {:follow_up, normalize(input)})

  @doc "Abort the active run."
  def abort(server), do: GenServer.cast(server, :abort)

  @doc "Snapshot of the current session state."
  def state(server), do: GenServer.call(server, :state)

  @doc """
  Clear the transcript and abort any active run. A reset marker is appended to
  the session file, so a crash-restarted (or resumed) session stays cleared.
  """
  def reset(server), do: GenServer.cast(server, :reset)

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    id = Keyword.fetch!(opts, :id)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    store = Store.new(cwd, id: id)

    state = %State{
      id: id,
      cwd: cwd,
      system_prompt: Keyword.get(opts, :system_prompt),
      model: Keyword.get(opts, :model),
      provider: Keyword.get(opts, :provider),
      # Default to the live extension set (built-ins + runtime-loaded tools),
      # resolved per turn by the loop. Pass an explicit list to pin tools.
      tools: Keyword.get(opts, :tools, :extensions),
      opts: Keyword.get(opts, :opts, []),
      store: store,
      # Resume the persisted transcript so a crash-restart (or reattach to a
      # known id) doesn't lose the conversation. Stored newest-first.
      messages: store.path |> Store.load() |> Enum.reverse()
    }

    Catalyst.Debug.mark_latest(id)
    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, msg}, _from, %State{run: nil} = state) do
    case start_run(state, [msg]) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, _reason} = err -> {:reply, err, state}
    end
  end

  def handle_call({:prompt, _msg}, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call(:continue, _from, %State{run: nil} = state) do
    case start_run(state, []) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, _reason} = err -> {:reply, err, state}
    end
  end

  def handle_call(:continue, _from, state), do: {:reply, {:error, :busy}, state}

  # Drains are scoped to the run that asked: a drain from a dead run (buffered
  # behind the abort that cleared run_ref) carries a stale ref and must reply []
  # WITHOUT touching the queues — otherwise it would move queued messages into
  # in_flight for a run that can never deliver them, and the next run's AgentEnd
  # would silently drop them.
  def handle_call({:drain_steering, ref}, _from, %State{run_ref: ref} = state)
      when ref != nil do
    {msgs, q} = drain_queue(state.steering)
    in_flight = state.in_flight ++ Enum.map(msgs, &{:steering, &1})
    {:reply, msgs, %{state | steering: q, in_flight: in_flight}}
  end

  def handle_call({:drain_steering, _stale_ref}, _from, state), do: {:reply, [], state}

  def handle_call({:drain_follow_up, ref}, _from, %State{run_ref: ref} = state)
      when ref != nil do
    {msgs, q} = drain_queue(state.follow_up)
    in_flight = state.in_flight ++ Enum.map(msgs, &{:follow_up, &1})
    {:reply, msgs, %{state | follow_up: q, in_flight: in_flight}}
  end

  def handle_call({:drain_follow_up, _stale_ref}, _from, state), do: {:reply, [], state}

  def handle_call(:state, _from, state), do: {:reply, Snapshot.of(state), state}

  @impl true
  def handle_cast({:steer, msg}, state),
    do: {:noreply, %{state | steering: :queue.in(msg, state.steering)}}

  def handle_cast({:follow_up, msg}, state),
    do: {:noreply, %{state | follow_up: :queue.in(msg, state.follow_up)}}

  def handle_cast(:abort, %State{run: %Task{} = task} = state) do
    # Clear run_ref FIRST: events the killed task already cast are still queued
    # behind this message and must not fold into the post-abort state.
    state = %{state | run_ref: nil}

    state =
      case {shutdown_run(task), state.agent_ended} do
        # Task completed AND its AgentEnd was already folded — nothing was lost.
        {{:ok, _result}, true} ->
          %{state | run: nil}

        # Killed, or completed with its tail events (final MessageEnd/AgentEnd)
        # queued behind this abort and dropped as stale: synthesize the aborted
        # turn so streaming/pending state is reset and subscribers always get
        # an AgentEnd (the UI unlocks input on it).
        _ ->
          handle_failure(%{state | run: nil}, :killed)
      end

    {:noreply, state}
  end

  def handle_cast(:abort, state), do: {:noreply, state}

  def handle_cast(:reset, state) do
    state =
      case state.run do
        %Task{} = task ->
          shutdown_run(task)
          state = %{state | run: nil, run_ref: nil}
          # Unlock subscribers waiting on the killed run. No aborted-turn
          # marker is synthesized — the transcript is being cleared anyway.
          broadcast(state, %Event.AgentEnd{messages: []})
          state

        _ ->
          state
      end

    # Persist the reset: Store.load/1 discards everything before the marker,
    # so a crash-restart or resume stays cleared.
    Store.append_reset(state.store)

    {:noreply,
     %{
       state
       | messages: [],
         streaming_message: nil,
         streaming_text: [],
         streaming_thinking: [],
         pending_tool_calls: MapSet.new(),
         error_message: nil,
         agent_ended: false,
         steering: :queue.new(),
         follow_up: :queue.new(),
         in_flight: []
     }}
  end

  def handle_cast({:agent_event, run_ref, event}, %State{run_ref: run_ref} = state)
      when run_ref != nil do
    Catalyst.Debug.log_event(state.id, event)
    persist(state, event)
    state = Reducer.reduce(event, state)
    broadcast(state, event)
    {:noreply, track_agent_end(state, event)}
  end

  # Stale event from an aborted/replaced run — drop it.
  def handle_cast({:agent_event, _stale_ref, _event}, state), do: {:noreply, state}

  @impl true
  # Task returned normally — its events already drove the state (casts from the
  # task are ordered before its completion message).
  def handle_info({ref, _result}, %State{run: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | run: nil, run_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, %State{run: %Task{ref: ref}} = state),
    do: {:noreply, %{state | run: nil, run_ref: nil}}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{run: %Task{ref: ref}} = state),
    do: {:noreply, handle_failure(%{state | run_ref: nil}, reason)}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{run: %Task{} = task}) do
    shutdown_run(task)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---- internals ------------------------------------------------------------

  defp start_run(state, prompts) do
    server = self()
    run_ref = make_ref()

    # Both resolve fresh per run, as data: the system prompt falls back to
    # ~/.catalyst/system_prompt.md (then the built-in default), and the loop
    # module comes from RunConfig (session opt → :agent_loop env → Agent.Loop) —
    # so prompt edits and loop swaps take effect on the next run, no restart.
    context = %{
      system_prompt: state.system_prompt || Catalyst.SystemPrompt.get(),
      messages: Enum.reverse(state.messages)
    }

    case RunConfig.build(state, server, run_ref) do
      {:ok, config} ->
        loop = Map.get(config, :loop, Loop)
        emit = fn event -> GenServer.cast(server, {:agent_event, run_ref, event}) end

        task =
          Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
            loop.run(prompts, context, config, emit)
          end)

        {:ok, %{state | run: task, run_ref: run_ref, agent_ended: false, error_message: nil}}

      {:error, _reason} = err ->
        err
    end
  end

  defp persist(state, %Event.MessageEnd{message: m}), do: Store.append_message(state.store, m)
  defp persist(_state, _event), do: :ok

  defp track_agent_end(state, %Event.AgentEnd{}), do: %{state | agent_ended: true}
  defp track_agent_end(state, _event), do: state

  defp handle_failure(state, reason) do
    Catalyst.Debug.log(
      state.id,
      "error",
      "run failed: " <> Catalyst.Debug.truncate(reason, 8_000)
    )

    msg = Reducer.failure_message(state, reason)
    Store.append_message(state.store, msg)

    state = %{
      state
      | messages: [msg | state.messages],
        error_message: msg.error_message,
        run: nil,
        pending_tool_calls: MapSet.new(),
        streaming_message: nil,
        streaming_text: [],
        streaming_thinking: [],
        # Steering/follow-ups the dead run drained but never delivered go back
        # to the front of their queues, so the user's message isn't lost.
        steering: requeue(state.in_flight, :steering, state.steering),
        follow_up: requeue(state.in_flight, :follow_up, state.follow_up),
        in_flight: []
    }

    broadcast(state, %Event.MessageEnd{message: msg})
    broadcast(state, %Event.AgentEnd{messages: [msg]})
    state
  end

  defp requeue(in_flight, kind, queue) do
    in_flight
    |> Enum.filter(&match?({^kind, _}, &1))
    |> Enum.reverse()
    |> Enum.reduce(queue, fn {_kind, msg}, q -> :queue.in_r(msg, q) end)
  end

  # Tagged with the session id so a subscriber that switched sessions can drop
  # events from the old one still buffered in its mailbox.
  defp broadcast(state, event) do
    Phoenix.PubSub.broadcast(Catalyst.PubSub, topic(state.id), {:agent_event, state.id, event})
  end

  defp shutdown_run(%Task{} = task), do: Task.shutdown(task, :brutal_kill)

  defp drain_queue(q), do: {:queue.to_list(q), :queue.new()}

  defp normalize(%Message.User{} = m), do: m
  defp normalize(text) when is_binary(text), do: Message.user(text)
  defp normalize(content) when is_list(content), do: Message.user(content)
end
