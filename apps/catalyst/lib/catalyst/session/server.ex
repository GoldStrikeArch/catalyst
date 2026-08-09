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
  require Logger

  alias Catalyst.Agent.Event
  alias Catalyst.{Message, Tasks}

  alias Catalyst.Session.{
    EventSink,
    Manager,
    Reducer,
    RunConfig,
    RunContext,
    Snapshot,
    Store
  }

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
  the session file before live state changes, so a crash-restarted (or resumed)
  session stays cleared. Returns a tagged persistence error without changing the
  session when the marker cannot be appended.
  """
  @spec reset(GenServer.server()) :: :ok | {:error, term()}
  def reset(server), do: GenServer.call(server, :reset)

  @doc """
  Reconfigure the session for subsequent runs: `:model` (a `%Catalyst.Model{}`),
  `:provider`, and/or `:opts` (a keyword merged into the session opts; a nil
  value deletes the key). Takes effect on the NEXT run — an in-flight run keeps
  the config it started with (`RunConfig.build/3` reads state per run).
  """
  @spec configure(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def configure(server, changes) when is_list(changes),
    do: GenServer.call(server, {:configure, changes})

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    id = Keyword.fetch!(opts, :id)

    with {:ok, cwd} <- session_cwd(opts),
         {:ok, store} <- open_store(cwd, opts) do
      state = %State{
        id: id,
        cwd: cwd,
        system_prompt: Keyword.get(opts, :system_prompt),
        model: Keyword.get(opts, :model),
        provider: Keyword.get(opts, :provider),
        # Default to the live extension set (built-ins + runtime-loaded tools),
        # resolved per turn by the loop. Pass an explicit list to pin tools.
        tools: Keyword.get(opts, :tools, :extensions),
        opts: initial_session_opts(opts),
        store: store,
        parent_id: Keyword.get(opts, :parent_id),
        root_session_id: Keyword.get(opts, :root_session_id, id),
        agent_depth: Keyword.get(opts, :agent_depth, 0)
      }

      {:ok, state, {:continue, :load_state}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:load_state, %State{} = state) do
    # One disk fold restores both the transcript and the independent session
    # settings. Persisted changes win over caller defaults, including explicit
    # nil tombstones used to clear a previously selected model/effort.
    case Store.load_state(state.store.path) do
      {:ok, loaded} ->
        # The previous incarnation may have died mid-run (graceful stop, VM crash)
        # after persisting an assistant message whose tool calls never got results.
        # Repair before the server handles mailbox messages so the next provider
        # request cannot observe dangling tool calls.
        state =
          state
          |> restore_persisted(loaded)
          |> repair_transcript()

        case state.parent_id do
          nil -> Catalyst.Debug.mark_latest_async(state.id)
          _parent -> :ok
        end

        # Fire-and-forget provider warmup (the Codex ws prewarm): the first turn
        # can then ride a delta upload. RunConfig decides (hot-swappable) and the
        # work runs in a supervised task — it never blocks or fails the session.
        {:noreply, start_prewarm(state)}

      {:error, reason} ->
        Logger.error(
          "[session:#{state.id}] failed to load state from #{state.store.path}: #{inspect(reason)}"
        )

        {:stop, {:load_failed, reason}, state}
    end
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

  def handle_call(
        {:register_run_resource, run_ref, resource},
        _from,
        %State{run_ref: run_ref} = state
      )
      when run_ref != nil do
    {_resource, state} = track_run_resource(state, resource)
    {:reply, :ok, state}
  end

  # Stale registrations must not reply :ok: the summarizer registers before
  # opening the companion resource, and an :ok would let it create state after
  # abort cleanup and then die without its after block.
  def handle_call({:register_run_resource, _stale_ref, _resource}, _from, state) do
    {:reply, {:error, :stale_run}, state}
  end

  # Durable events (ContextCompacted) are folded synchronously so the run task
  # holds until the replacement is persisted before requesting the provider.
  # Same-process casts sent earlier are already ordered before this call.
  def handle_call({:persist_run_event, run_ref, event}, _from, %State{run_ref: run_ref} = state)
      when run_ref != nil do
    case persist_and_accept(state, event) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:persist_run_event, _stale_ref, _event}, _from, state) do
    {:reply, {:error, :stale_run}, state}
  end

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

    case persist_settings_snapshot(state, new_state) do
      :ok ->
        # Changed model/options invalidate any prewarmed continuation's body
        # probe. Cancel the previous warmup before starting its replacement so it
        # cannot land stale state after the new configuration wins.
        {:reply, :ok, restart_prewarm(new_state)}

      {:error, reason} ->
        log_persistence_failure(state, :settings_snapshot, reason)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    # The reset marker is authoritative state, like a compaction replacement.
    # Append it before killing the run or changing memory: on failure the live
    # session continues unchanged and restart cannot resurrect cleared history.
    case Store.append_reset(state.store) do
      :ok ->
        {:reply, :ok, install_reset(state)}

      {:error, reason} ->
        log_persistence_failure(state, :reset, reason)
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:steer, msg}, state),
    do: {:noreply, %{state | steering: :queue.in(msg, state.steering)}}

  def handle_cast({:follow_up, msg}, state),
    do: {:noreply, %{state | follow_up: :queue.in(msg, state.follow_up)}}

  def handle_cast(:abort, %State{run: %Task{} = task} = state) do
    # Clear run_ref FIRST: events the killed task already cast are still queued
    # behind this message and must not fold into the post-abort state.
    # Kill the run before releasing resources so it cannot recreate companion
    # state after cleanup; finish_successful_run/handle_failure clean after.
    state = %{state | run_ref: nil}
    result = shutdown_run(task)
    state = %{state | run: nil}

    state =
      case {result, state.agent_ended} do
        # Task completed AND its AgentEnd was already folded — nothing was lost.
        {{:ok, _result}, true} ->
          finish_successful_run(state)

        # Killed, or completed with its tail events (final MessageEnd/AgentEnd)
        # queued behind this abort and dropped as stale: synthesize the aborted
        # turn so streaming/pending state is reset and subscribers always get
        # an AgentEnd (the UI unlocks input on it).
        _ ->
          handle_failure(state, :killed)
      end

    {:noreply, state}
  end

  def handle_cast(:abort, state), do: {:noreply, state}

  def handle_cast({:run_metadata, run_ref, metadata}, %State{run_ref: run_ref} = state)
      when run_ref != nil do
    {:noreply, %{state | current_run_metadata: metadata}}
  end

  def handle_cast({:run_metadata, _stale_ref, _metadata}, state), do: {:noreply, state}

  def handle_cast({:agent_event, run_ref, event}, %State{run_ref: run_ref} = state)
      when run_ref != nil do
    {:noreply, fold_run_event(state, event)}
  end

  # Stale event from an aborted/replaced run — drop it.
  def handle_cast({:agent_event, _stale_ref, _event}, state), do: {:noreply, state}

  @impl true
  # Task returned normally — its events already drove the state (casts from the
  # task are ordered before its completion message).
  def handle_info({ref, {:run_error, reason}}, %State{run: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_failure(%{state | run_ref: nil}, reason)}
  end

  def handle_info({ref, {:workflow_result, _result}}, %State{run: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = finish_successful_run(state)
    {:noreply, %{state | run: nil, run_ref: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %State{prewarm: {_prewarm_pid, ref}} = state
      ),
      do: {:noreply, %{state | prewarm: nil}}

  def handle_info({:DOWN, ref, :process, _pid, :normal}, %State{run: %Task{ref: ref}} = state) do
    {:noreply, handle_failure(%{state | run_ref: nil}, {:workflow_exit, :normal})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{run: %Task{ref: ref}} = state),
    do: {:noreply, handle_failure(%{state | run_ref: nil}, reason)}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{} = state) do
    _state = stop_prewarm(state)
    shutdown_terminating_run(state.run)
    cleanup_run_resources(state)
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
    # Terminal paths already released companions. Every compaction resource has
    # a unique provider continuation id, so cleanup is independent per run.
    state = cleanup_run_resources(state)
    server = self()
    run_ref = make_ref()

    # Provider availability remains a synchronous host-owned preflight. Prompt,
    # workflow, catalog, and extension policy code starts only inside the task.
    case RunConfig.resolve_provider(state) do
      {:ok, provider} ->
        task = Tasks.async(fn -> run_task_body(state, server, run_ref, provider, prompts) end)
        {:ok, reset_for_run(state, task, run_ref)}

      {:error, _reason} = error ->
        error
    end
  end

  defp run_task_body(state, server, run_ref, provider, prompts) do
    emit = fn event -> GenServer.cast(server, {:agent_event, run_ref, event}) end

    case RunContext.build(state, server, run_ref, provider) do
      {:ok, run_context} ->
        GenServer.cast(server, {:run_metadata, run_ref, run_context.metadata})

        prompts
        |> run_context.config.loop.run(run_context.context, run_context.config, emit)
        |> classify_workflow_result()

      {:error, reason} ->
        {:run_error, reason}
    end
  end

  defp classify_workflow_result({:ok, messages, final_context} = success)
       when is_list(messages) and is_map(final_context),
       do: {:workflow_result, success}

  defp classify_workflow_result({:error, reason}), do: {:run_error, reason}
  defp classify_workflow_result(invalid), do: {:run_error, {:invalid_workflow_result, invalid}}

  defp reset_for_run(state, task, run_ref) do
    %{
      state
      | run: task,
        run_ref: run_ref,
        agent_ended: false,
        run_final_assistant: nil,
        error_message: nil,
        current_run_metadata: nil,
        run_resources: []
    }
  end

  defp merge_opts(opts, changes) do
    Enum.reduce(changes, opts || [], fn
      {key, nil}, acc -> Keyword.delete(acc, key)
      {key, value}, acc -> Keyword.put(acc, key, value)
    end)
  end

  defp normalize_session_opts(opts), do: Keyword.delete(opts, :session_id)

  defp initial_session_opts(opts) do
    session_opts = opts |> Keyword.get(:opts, []) |> normalize_session_opts()

    case Keyword.get(opts, :workflow) do
      nil -> session_opts
      workflow when is_binary(workflow) -> Keyword.put_new(session_opts, :workflow, workflow)
      %{name: name} when is_binary(name) -> Keyword.put_new(session_opts, :workflow, name)
      %{module: module} when is_atom(module) -> Keyword.put_new(session_opts, :loop, module)
      module when is_atom(module) -> Keyword.put_new(session_opts, :loop, module)
      _other -> session_opts
    end
  end

  defp session_cwd(opts) do
    case Keyword.fetch(opts, :cwd) do
      {:ok, cwd} when is_binary(cwd) ->
        {:ok, cwd}

      {:ok, cwd} ->
        {:error, {:invalid_cwd, cwd}}

      :error ->
        case Catalyst.Paths.default_cwd() do
          {:ok, cwd} -> {:ok, cwd}
          {:error, reason} -> {:error, {:cwd_failed, reason}}
        end
    end
  end

  defp open_store(cwd, opts) do
    store_opts =
      Keyword.take(opts, [:id, :parent_id, :root_session_id, :agent_depth])

    case Keyword.get(opts, :create) do
      :exclusive -> Store.create_new(cwd, store_opts)
      _resume_or_create -> Store.open(cwd, store_opts)
    end
  end

  defp restore_persisted(%State{} = state, loaded) do
    %State{
      state
      | model: restore_model(state.model, loaded),
        opts: restore_thinking_level(state.opts, loaded),
        messages: Enum.reverse(loaded.messages),
        parent_id: loaded.parent_id || state.parent_id,
        root_session_id: loaded.root_session_id || state.root_session_id || state.id,
        agent_depth: max(loaded.agent_depth, state.agent_depth)
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

  defp persist(state, %Event.ContextCompacted{} = event),
    do: Store.append_compaction(state.store, event)

  defp persist(_state, _event), do: :ok

  # Synthesize and persist error ToolResults for tool calls left dangling by a
  # previous incarnation. No broadcast: this runs in handle_continue before
  # the server processes mailbox messages.
  defp repair_transcript(state) do
    case Reducer.aborted_tool_results(state, :interrupted) do
      [] ->
        state

      results ->
        Enum.each(results, fn result ->
          append_best_effort(state, :transcript_repair, fn ->
            Store.append_message(state.store, result)
          end)
        end)

        %{state | messages: Enum.reverse(results, state.messages)}
    end
  end

  # Compaction is authoritative replacement state, so it is accepted only
  # after its JSONL append succeeds. Ordinary MessageEnd events intentionally
  # retain the prior best-effort persistence policy: a disk failure is surfaced
  # in logs but does not crash or halt an otherwise live run.
  defp fold_run_event(state, %Event.ContextCompacted{} = event) do
    case persist_and_accept(state, event) do
      {:ok, state} ->
        state

      {:error, reason} ->
        log_persistence_failure(state, :compaction, reason)
        state
    end
  end

  defp fold_run_event(state, event) do
    persist_best_effort(state, event)
    accept_run_event(state, event)
  end

  defp persist_and_accept(state, event) do
    case persist(state, event) do
      :ok -> {:ok, accept_committed_event(state, event)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp accept_committed_event(state, event) do
    state = Reducer.reduce(event, state)
    :ok = EventSink.committed(event, state.id)
    broadcast(state, event)
    track_agent_end(state, event)
  end

  defp accept_run_event(state, event) do
    state = Reducer.reduce(event, state)
    broadcast(state, event)
    track_agent_end(state, event)
  end

  defp persist_best_effort(state, event) do
    case persist(state, event) do
      :ok -> :ok
      {:error, reason} -> log_persistence_failure(state, event_name(event), reason)
    end
  end

  defp track_agent_end(state, %Event.AgentEnd{}), do: %{state | agent_ended: true}
  defp track_agent_end(state, _event), do: state

  defp handle_failure(state, reason) do
    state = cleanup_run_resources(state)

    Catalyst.Debug.log_async(
      state.id,
      "error",
      "run failed: " <> Catalyst.Debug.truncate(Catalyst.Debug.scrub_term(reason), 8_000)
    )

    state = complete_orphaned_tool_calls(state, reason)

    msg = Reducer.failure_message(state, reason)

    append_best_effort(state, :failure_message, fn ->
      Store.append_message(state.store, msg)
    end)

    state = clear_failed_run(state, msg)
    synthetic_and_broadcast(state, %Event.MessageEnd{message: msg})
    synthetic_and_broadcast(state, %Event.AgentEnd{messages: [msg]})
    state
  end

  # Complete orphaned tool calls first: the assistant message carrying them
  # was already persisted, and a transcript with a tool call but no result is
  # rejected by the provider on every subsequent request.
  defp complete_orphaned_tool_calls(state, reason) do
    case Reducer.aborted_tool_results(state, reason) do
      [] ->
        state

      results ->
        Enum.each(results, fn result ->
          append_best_effort(state, :aborted_tool_result, fn ->
            Store.append_message(state.store, result)
          end)

          synthetic_and_broadcast(state, %Event.MessageEnd{message: result})
        end)

        %{state | messages: Enum.reverse(results, state.messages)}
    end
  end

  defp clear_failed_run(state, msg) do
    %{
      state
      | messages: [msg | state.messages],
        error_message: msg.error_message,
        run: nil,
        pending_tool_calls: MapSet.new(),
        streaming_message: nil,
        streaming_text: [],
        streaming_thinking: [],
        current_run_metadata: nil,
        run_final_assistant: nil,
        # Steering/follow-ups the dead run drained but never delivered go back
        # to the front of their queues, so the user's message isn't lost.
        steering: requeue(state.in_flight, :steering, state.steering),
        follow_up: requeue(state.in_flight, :follow_up, state.follow_up),
        in_flight: []
    }
  end

  defp requeue(in_flight, kind, queue) do
    in_flight
    |> Enum.filter(&match?({^kind, _}, &1))
    |> Enum.reverse()
    |> Enum.reduce(queue, fn {_kind, msg}, q -> :queue.in_r(msg, q) end)
  end

  defp synthetic_and_broadcast(state, event) do
    EventSink.synthetic(event, state.id)
    broadcast(state, event)
  end

  # Tagged with the session id so a subscriber that switched sessions can drop
  # events from the old one still buffered in its mailbox.
  defp broadcast(state, event) do
    Phoenix.PubSub.broadcast(Catalyst.PubSub, topic(state.id), {:agent_event, state.id, event})
  end

  defp shutdown_run(%Task{} = task), do: Task.shutdown(task, :brutal_kill)

  defp drain_queue(q), do: {:queue.to_list(q), :queue.new()}

  defp install_reset(state) do
    state = stop_reset_run(state)

    %{
      state
      | messages: [],
        streaming_message: nil,
        streaming_text: [],
        streaming_thinking: [],
        pending_tool_calls: MapSet.new(),
        error_message: nil,
        agent_ended: false,
        run_final_assistant: nil,
        steering: :queue.new(),
        follow_up: :queue.new(),
        in_flight: [],
        current_run_metadata: nil,
        run_resources: []
    }
  end

  defp stop_reset_run(%State{run: %Task{} = task} = state) do
    shutdown_run(task)

    state =
      state
      |> cleanup_run_resources()
      |> then(&%{&1 | run: nil, run_ref: nil})

    # Unlock subscribers waiting on the killed run. No aborted-turn marker is
    # synthesized because the successfully persisted reset clears the turn.
    synthetic_and_broadcast(state, %Event.AgentEnd{messages: []})
    state
  end

  defp stop_reset_run(state), do: cleanup_run_resources(state)

  defp normalize(%Message.User{} = m), do: m
  defp normalize(text) when is_binary(text), do: Message.user(text)
  defp normalize(content) when is_list(content), do: Message.user(content)

  # Persist a single replayable settings record before changing live state. The
  # loader keeps decoding legacy model_change/thinking_level_change records.
  defp persist_settings_snapshot(old, new) do
    case persisted_settings_changed?(old, new) do
      true ->
        Store.append_settings_snapshot(
          new.store,
          new.model,
          Keyword.get(new.opts, :reasoning_effort)
        )

      false ->
        :ok
    end
  end

  defp persisted_settings_changed?(old, new) do
    old.model != new.model or
      Keyword.get(old.opts, :reasoning_effort) != Keyword.get(new.opts, :reasoning_effort)
  end

  defp finish_successful_run(state) do
    state = cleanup_run_resources(state)

    case state.agent_ended and successful_final_assistant?(state.run_final_assistant) do
      true ->
        %{
          state
          | last_successful_run_metadata: state.current_run_metadata,
            current_run_metadata: nil,
            run_resources: [],
            run_final_assistant: nil
        }

      false ->
        %{state | current_run_metadata: nil, run_resources: [], run_final_assistant: nil}
    end
  end

  defp successful_final_assistant?(%Message.Assistant{stop_reason: reason})
       when reason not in [:error, :aborted],
       do: true

  defp successful_final_assistant?(_assistant), do: false

  defp track_run_resource(state, resource) when is_map(resource) do
    {resource, %{state | run_resources: [resource | state.run_resources || []]}}
  end

  defp cleanup_run_resources(state) do
    Enum.each(state.run_resources || [], fn resource ->
      Tasks.start_background(fn -> cleanup_resource_now(resource) end)
    end)

    %{state | run_resources: []}
  end

  defp cleanup_resource_now(%{provider: provider, session_id: session_id})
       when is_atom(provider) and is_binary(session_id) do
    case function_exported?(provider, :cleanup_session, 1) do
      true -> provider.cleanup_session(session_id)
      false -> :ok
    end

    :ok
  catch
    kind, reason ->
      Logger.warning(
        "session resource cleanup #{inspect(provider)}/#{inspect(session_id)} " <>
          "#{kind}: #{inspect(reason)}"
      )

      :ok
  end

  defp cleanup_resource_now(_resource), do: :ok

  defp append_best_effort(state, operation, append) when is_function(append, 0) do
    case append.() do
      :ok -> :ok
      {:error, reason} -> log_persistence_failure(state, operation, reason)
    end
  end

  defp log_persistence_failure(state, operation, reason) do
    Logger.warning(
      "session #{state.id}: failed to persist #{inspect(operation)} to #{state.store.path}: " <>
        inspect(reason, limit: 20, printable_limit: 1_000)
    )

    :ok
  end

  defp event_name(%module{}), do: module
end
