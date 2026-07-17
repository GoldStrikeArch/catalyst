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
  alias Catalyst.{Message, Tasks}
  alias Catalyst.Session.{Manager, Reducer, RunConfig, Snapshot, Store}
  alias Catalyst.Session.Server.State

  # ---- public API -----------------------------------------------------------

  @typedoc "User input accepted by `prompt/2`, `steer/2`, and `follow_up/2`."
  @type input :: Message.User.t() | String.t() | [Catalyst.Content.t()]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: Manager.via(id))
  end

  @doc "PubSub topic for a session id."
  @spec topic(String.t()) :: String.t()
  def topic(id), do: "session:" <> id

  @doc """
  Queue a user prompt and start a run. Returns `:ok`, `{:error, :busy}`, or
  `{:error, :no_provider | {:unknown_api, api}}` when the session has no
  resolvable provider.
  """
  @spec prompt(GenServer.server(), input()) :: :ok | {:error, term()}
  def prompt(server, input), do: GenServer.call(server, {:prompt, normalize(input)})

  @doc "Continue running (no new prompt) — e.g. after steering/follow-up. Same returns as `prompt/2`."
  @spec continue(GenServer.server()) :: :ok | {:error, term()}
  def continue(server), do: GenServer.call(server, :continue)

  @doc "Inject a message mid-run, applied before the next LLM call."
  @spec steer(GenServer.server(), input()) :: :ok
  def steer(server, input), do: GenServer.cast(server, {:steer, normalize(input)})

  @doc "Queue a message to run after the agent reaches a natural stop."
  @spec follow_up(GenServer.server(), input()) :: :ok
  def follow_up(server, input), do: GenServer.cast(server, {:follow_up, normalize(input)})

  @doc "Abort the active run."
  @spec abort(GenServer.server()) :: :ok
  def abort(server), do: GenServer.cast(server, :abort)

  @doc "Snapshot of the current session state (see `Catalyst.Session.Snapshot.of/1`)."
  @spec state(GenServer.server()) :: map()
  def state(server), do: GenServer.call(server, :state)

  @doc """
  Clear the transcript and abort any active run. A reset marker is appended to
  the session file, so a crash-restarted (or resumed) session stays cleared.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server), do: GenServer.cast(server, :reset)

  @doc """
  Reconfigure the session for subsequent runs: `:model` (a `%Catalyst.Model{}`),
  `:provider`, and/or `:opts` (a keyword merged into the session opts; a nil
  value deletes the key). Takes effect on the NEXT run — an in-flight run keeps
  the config it started with (`RunConfig.build/3` reads state per run).
  """
  @spec configure(GenServer.server(), keyword()) :: :ok
  def configure(server, changes) when is_list(changes),
    do: GenServer.call(server, {:configure, changes})

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
      opts: opts |> Keyword.get(:opts, []) |> normalize_session_opts(),
      store: store
    }

    {:ok, state, {:continue, :load_state}}
  end

  @impl true
  def handle_continue(:load_state, %State{} = state) do
    # One disk fold restores both the transcript and the independent session
    # settings. Persisted changes win over caller defaults, including explicit
    # nil tombstones used to clear a previously selected model/effort.
    loaded = Store.load_state(state.store.path)

    # The previous incarnation may have died mid-run (graceful stop, VM crash)
    # after persisting an assistant message whose tool calls never got results.
    # Repair before the server handles mailbox messages so the next provider
    # request cannot observe dangling tool calls.
    state =
      state
      |> restore_persisted(loaded)
      |> repair_transcript()

    Catalyst.Debug.mark_latest(state.id)
    # Fire-and-forget provider warmup (the Codex ws prewarm): the first turn
    # can then ride a delta upload. RunConfig decides (hot-swappable) and the
    # work runs in a supervised task — it never blocks or fails the session.
    {:noreply, start_prewarm(state)}
  end

  @impl true
  def handle_call({:prompt, msg}, _from, %State{run: nil} = state) do
    state = stop_prewarm(state)

    case start_run(state, [msg]) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, _reason} = err -> {:reply, err, state}
    end
  end

  def handle_call({:prompt, _msg}, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call(:continue, _from, %State{run: nil} = state) do
    state = stop_prewarm(state)

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

  def handle_call({:configure, changes}, _from, %State{} = state) do
    new_state = %State{
      state
      | model: Keyword.get(changes, :model, state.model),
        provider: Keyword.get(changes, :provider, state.provider),
        opts:
          state.opts
          |> merge_opts(Keyword.get(changes, :opts, []))
          |> normalize_session_opts()
    }

    persist_settings_changes(state, new_state)

    # Changed model/options invalidate any prewarmed continuation's body
    # probe. Cancel the previous warmup before starting its replacement so it
    # cannot land stale state after the new configuration wins.
    {:reply, :ok, restart_prewarm(new_state)}
  end

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

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %State{prewarm: {_prewarm_pid, ref}} = state
      ),
      do: {:noreply, %{state | prewarm: nil}}

  def handle_info({:DOWN, ref, :process, _pid, :normal}, %State{run: %Task{ref: ref}} = state),
    do: {:noreply, %{state | run: nil, run_ref: nil}}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{run: %Task{ref: ref}} = state),
    do: {:noreply, handle_failure(%{state | run_ref: nil}, reason)}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{} = state) do
    _state = stop_prewarm(state)
    shutdown_terminating_run(state.run)
    RunConfig.cleanup_session(state)
    :ok
  end

  # ---- internals ------------------------------------------------------------

  defp shutdown_terminating_run(%Task{} = task), do: shutdown_run(task)
  defp shutdown_terminating_run(_no_run), do: :ok

  defp start_prewarm(%State{} = state) do
    case RunConfig.start_prewarm(state) do
      {:ok, pid} -> %{state | prewarm: {pid, Process.monitor(pid)}}
      _not_started -> %{state | prewarm: nil}
    end
  end

  defp restart_prewarm(%State{run: nil} = state),
    do: state |> stop_prewarm() |> start_prewarm()

  defp restart_prewarm(%State{} = state), do: stop_prewarm(state)

  defp stop_prewarm(%State{prewarm: nil} = state), do: state

  defp stop_prewarm(%State{prewarm: {pid, ref}} = state) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end

    RunConfig.cleanup_session(state)
    %{state | prewarm: nil}
  end

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

        task = Tasks.async(fn -> loop.run(prompts, context, config, emit) end)

        {:ok, %{state | run: task, run_ref: run_ref, agent_ended: false, error_message: nil}}

      {:error, _reason} = err ->
        err
    end
  end

  defp merge_opts(opts, changes) do
    Enum.reduce(changes, opts || [], fn
      {key, nil}, acc -> Keyword.delete(acc, key)
      {key, value}, acc -> Keyword.put(acc, key, value)
    end)
  end

  defp normalize_session_opts(opts), do: Keyword.delete(opts, :session_id)

  defp restore_persisted(%State{} = state, loaded) do
    %State{
      state
      | model: restore_model(state.model, loaded),
        opts: restore_thinking_level(state.opts, loaded),
        messages: Enum.reverse(loaded.messages)
    }
  end

  defp restore_model(_default, %{model_set?: true, model: model}), do: model
  defp restore_model(default, _settings), do: default

  defp restore_thinking_level(opts, %{thinking_level_set?: true, thinking_level: nil}),
    do: Keyword.delete(opts, :reasoning_effort)

  defp restore_thinking_level(opts, %{thinking_level_set?: true, thinking_level: level}),
    do: Keyword.put(opts, :reasoning_effort, level)

  defp restore_thinking_level(opts, _settings), do: opts

  defp persist(state, %Event.MessageEnd{message: m}), do: Store.append_message(state.store, m)
  defp persist(_state, _event), do: :ok

  # Synthesize and persist error ToolResults for tool calls left dangling by a
  # previous incarnation. No broadcast: this runs in handle_continue before
  # the server processes mailbox messages.
  defp repair_transcript(state) do
    case Reducer.aborted_tool_results(state, :interrupted) do
      [] ->
        state

      results ->
        Enum.each(results, &Store.append_message(state.store, &1))
        %{state | messages: Enum.reverse(results, state.messages)}
    end
  end

  defp track_agent_end(state, %Event.AgentEnd{}), do: %{state | agent_ended: true}
  defp track_agent_end(state, _event), do: state

  defp handle_failure(state, reason) do
    Catalyst.Debug.log(
      state.id,
      "error",
      "run failed: " <> Catalyst.Debug.truncate(reason, 8_000)
    )

    # Complete orphaned tool calls first: the assistant message carrying them
    # was already persisted, and a transcript with a tool call but no result is
    # rejected by the provider on every subsequent request.
    state =
      case Reducer.aborted_tool_results(state, reason) do
        [] ->
          state

        results ->
          Enum.each(results, fn r ->
            Store.append_message(state.store, r)
            broadcast(state, %Event.MessageEnd{message: r})
          end)

          %{state | messages: Enum.reverse(results, state.messages)}
      end

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

  # PI's model_change / thinking_level_change session entries: persist setting
  # switches so a resumed session keeps them (handle_continue folds them back).
  defp persist_settings_changes(old, new) do
    case new.model != old.model and
           (is_nil(new.model) or match?(%Catalyst.Model{}, new.model)) do
      true -> Store.append_model_change(new.store, new.model)
      false -> :ok
    end

    old_level = Keyword.get(old.opts, :reasoning_effort)
    new_level = Keyword.get(new.opts, :reasoning_effort)

    case new_level != old_level and (is_nil(new_level) or is_binary(new_level)) do
      true -> Store.append_thinking_level_change(new.store, new_level)
      false -> :ok
    end

    :ok
  end
end
