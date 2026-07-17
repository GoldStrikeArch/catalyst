defmodule Catalyst.Session.Server do
  @moduledoc """
  Stateful owner of one session (PI's `Agent` class).

  The single writer of the transcript, model, queues, and pending-tool state. A
  `prompt`/`continue` runs `Catalyst.Agent.Loop` in a supervised Task; the loop
  emits events back as `{:agent_event, e}` casts, which this server folds into
  state (append on `message_end`, persist to JSONL, track pending tool calls) and
  re-broadcasts on `"session:<id>"` for any subscribers (LiveViews/CLI).

  Cancellation is process kill: `abort/1` kills the run Task; its linked
  ports/MuonTrap daemons die with it, and an aborted turn is synthesized.
  """

  use GenServer

  alias Catalyst.Agent.{Event, Loop}
  alias Catalyst.{Content, Message}
  alias Catalyst.Session.{Manager, Store}

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
      messages: [],
      streaming_message: nil,
      pending_tool_calls: MapSet.new(),
      error_message: nil,
      steering: :queue.new(),
      follow_up: :queue.new()
    ]
  end

  # ---- public API -----------------------------------------------------------

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: Manager.via(id))
  end

  @doc "PubSub topic for a session id."
  def topic(id), do: "session:" <> id

  @doc "Queue a user prompt and start a run. Returns `:ok` or `{:error, :busy}`."
  def prompt(server, input), do: GenServer.call(server, {:prompt, normalize(input)})

  @doc "Continue running (no new prompt) — e.g. after steering/follow-up."
  def continue(server), do: GenServer.call(server, :continue)

  @doc "Inject a message mid-run, applied before the next LLM call."
  def steer(server, input), do: GenServer.cast(server, {:steer, normalize(input)})

  @doc "Queue a message to run after the agent reaches a natural stop."
  def follow_up(server, input), do: GenServer.cast(server, {:follow_up, normalize(input)})

  @doc "Abort the active run (process kill)."
  def abort(server), do: GenServer.cast(server, :abort)

  @doc "Snapshot of the current session state."
  def state(server), do: GenServer.call(server, :state)

  @doc "Clear the transcript (keeps the same session file appended)."
  def reset(server), do: GenServer.cast(server, :reset)

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    cwd = Keyword.get(opts, :cwd, File.cwd!())

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
      store: Store.new(cwd, id: id)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, msg}, _from, %State{run: nil} = state),
    do: {:reply, :ok, start_run(state, [msg])}

  def handle_call({:prompt, _msg}, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call(:continue, _from, %State{run: nil} = state),
    do: {:reply, :ok, start_run(state, [])}

  def handle_call(:continue, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call(:drain_steering, _from, state) do
    {msgs, q} = drain_queue(state.steering)
    {:reply, msgs, %{state | steering: q}}
  end

  def handle_call(:drain_follow_up, _from, state) do
    {msgs, q} = drain_queue(state.follow_up)
    {:reply, msgs, %{state | follow_up: q}}
  end

  def handle_call(:state, _from, state), do: {:reply, snapshot(state), state}

  @impl true
  def handle_cast({:steer, msg}, state),
    do: {:noreply, %{state | steering: :queue.in(msg, state.steering)}}

  def handle_cast({:follow_up, msg}, state),
    do: {:noreply, %{state | follow_up: :queue.in(msg, state.follow_up)}}

  def handle_cast(:abort, %State{run: %Task{pid: pid}} = state) do
    Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_cast(:abort, state), do: {:noreply, state}

  def handle_cast(:reset, state),
    do: {:noreply, %{state | messages: [], streaming_message: nil, pending_tool_calls: MapSet.new(), error_message: nil}}

  def handle_cast({:agent_event, event}, state) do
    state = reduce(event, state)
    broadcast(state, event)
    {:noreply, state}
  end

  @impl true
  # Task returned normally — its events already drove the state.
  def handle_info({ref, _result}, %State{run: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | run: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, %State{run: %Task{ref: ref}} = state),
    do: {:noreply, %{state | run: nil}}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{run: %Task{ref: ref}} = state),
    do: {:noreply, handle_failure(state, reason)}

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- internals ------------------------------------------------------------

  defp start_run(state, prompts) do
    server = self()

    context = %{system_prompt: state.system_prompt, messages: state.messages}

    config = %{
      provider: state.provider,
      model: state.model,
      cwd: state.cwd,
      tools: state.tools,
      # Stable session id → Codex prompt_cache_key + request headers.
      opts: Keyword.put_new(state.opts, :session_id, state.id),
      get_steering: fn -> GenServer.call(server, :drain_steering) end,
      get_follow_up: fn -> GenServer.call(server, :drain_follow_up) end
    }

    emit = fn event -> GenServer.cast(server, {:agent_event, event}) end

    task =
      Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
        Loop.run(prompts, context, config, emit)
      end)

    %{state | run: task, error_message: nil}
  end

  defp reduce(%Event.MessageEnd{message: m}, state) do
    Store.append_message(state.store, m)
    streaming = if match?(%Message.Assistant{}, m), do: nil, else: state.streaming_message
    %{state | messages: state.messages ++ [m], streaming_message: streaming}
  end

  defp reduce(%Event.MessageStart{message: m}, state), do: %{state | streaming_message: m}

  defp reduce(%Event.ToolExecutionStart{call_id: id}, state),
    do: %{state | pending_tool_calls: MapSet.put(state.pending_tool_calls, id)}

  defp reduce(%Event.ToolExecutionEnd{call_id: id}, state),
    do: %{state | pending_tool_calls: MapSet.delete(state.pending_tool_calls, id)}

  defp reduce(_event, state), do: state

  defp handle_failure(state, reason) do
    {text, stop} =
      case reason do
        :killed -> {"Run aborted.", :aborted}
        other -> {"Run failed: #{inspect(other)}", :error}
      end

    msg = %Message.Assistant{
      content: Content.text(text),
      model: state.model && state.model.id,
      stop_reason: stop,
      error_message: text,
      timestamp: Message.now()
    }

    Store.append_message(state.store, msg)

    state = %{
      state
      | messages: state.messages ++ [msg],
        error_message: text,
        run: nil,
        pending_tool_calls: MapSet.new(),
        streaming_message: nil
    }

    broadcast(state, %Event.MessageEnd{message: msg})
    broadcast(state, %Event.AgentEnd{messages: [msg]})
    state
  end

  defp broadcast(state, event),
    do: Phoenix.PubSub.broadcast(Catalyst.PubSub, topic(state.id), {:agent_event, event})

  defp snapshot(state) do
    %{
      id: state.id,
      cwd: state.cwd,
      messages: state.messages,
      streaming_message: state.streaming_message,
      pending_tool_calls: MapSet.to_list(state.pending_tool_calls),
      running: state.run != nil,
      model: state.model,
      system_prompt: state.system_prompt,
      store_path: state.store.path,
      error_message: state.error_message
    }
  end

  defp drain_queue(q), do: {:queue.to_list(q), :queue.new()}

  defp normalize(%Message.User{} = m), do: m
  defp normalize(text) when is_binary(text), do: Message.user(text)
  defp normalize(content) when is_list(content), do: Message.user(content)
end
