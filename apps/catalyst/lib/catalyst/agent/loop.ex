defmodule Catalyst.Agent.Loop do
  @moduledoc """
  The core agentic loop (PI's `agent-loop.ts`). A plain recursive function: it
  streams an assistant turn, executes any tool calls, appends results, and
  repeats until a turn has no tool calls (or a tool batch terminates). Steering
  messages are injected before each LLM call; follow-up messages re-enter after a
  natural stop.

  Side effects happen only through `emit` (the event sink). The function is run
  inside a Task by `Catalyst.Session.Server`, which folds the events into state.

  `config` is a map:

      %{
        provider: module(),            # implements Catalyst.LLM.Provider
        model: Catalyst.Model.t(),
        cwd: String.t(),
        tools: [tool_module()],
        opts: keyword(),               # provider options
        convert_to_llm: ([msg] -> [msg]) | nil,
        get_steering: (-> [msg]) | nil,
        get_follow_up: (-> [msg]) | nil
      }

  `context` is `%{system_prompt: String.t() | nil, messages: [Catalyst.Message.t()]}`.
  """

  @behaviour Catalyst.Workflow

  alias Catalyst.Agent.{Event, ToolRunner}
  alias Catalyst.{Content, Extensions, Hooks, Message}

  alias Catalyst.Session.RunContext
  alias Catalyst.Workflow.Support

  @hook_snapshot_attempts 2

  @doc "Run the loop for the given prompts. Returns `{:ok, new_messages, final_context}`."
  @impl true
  @spec run([Message.t()], map(), map(), (Event.t() -> any())) ::
          {:ok, [Message.t()], map()} | {:error, term()}
  def run(prompts, context, config, emit) do
    emit = Support.observed_emit(emit, config)
    config = Map.put(config, :tool_profile, Support.tool_profile(config))

    emit.(%Event.AgentStart{})

    # User prompts flow through message_end like everything else, so the single
    # writer (Session.Server) appends/persists them uniformly.
    Enum.each(prompts, fn p -> emit.(%Event.MessageEnd{message: p}) end)
    context = %{context | messages: context.messages ++ prompts}

    # `acc` is carried NEWEST-FIRST (O(1) appends) and reversed once here.
    # `context.messages` stays chronological: its batch appends are O(n) per
    # turn, which the per-turn LLM request building costs anyway.
    case outer_loop(context, Enum.reverse(prompts), config, emit) do
      {:ok, context, acc} ->
        new_messages = Enum.reverse(acc)
        emit.(%Event.AgentEnd{messages: new_messages})
        {:ok, new_messages, context}

      {:error, reason, _context, _acc} ->
        {:error, reason}
    end
  end

  # Outer loop: after the inner loop reaches a natural stop, drain follow-ups.
  # A halted run (provider error/abort, or a should_stop_after_turn veto) skips
  # them — queued follow-ups wait for the next run instead of re-firing into a
  # failed provider.
  defp outer_loop(context, acc, config, emit) do
    case inner_loop(context, acc, config, emit) do
      {:halt, context, acc} ->
        {:ok, context, acc}

      {:stop, context, acc, next_config} ->
        case drain(next_config[:get_follow_up]) do
          [] ->
            {:ok, context, acc}

          follow ->
            Enum.each(follow, fn m -> emit.(%Event.MessageEnd{message: m}) end)
            context = %{context | messages: context.messages ++ follow}
            outer_loop(context, Enum.reverse(follow, acc), next_config, emit)
        end

      {:error, reason, context, acc} ->
        {:error, reason, context, acc}
    end
  end

  # Inner loop: stream a turn, run tools, repeat while tool calls (or steering
  # messages) remain. Returns `{:stop, ..., config}` on a natural stop so
  # hook-updated config reaches follow-ups, or `{:halt, ...}` on a hard stop.
  defp inner_loop(context, acc, config, emit) do
    {context, acc} = inject_steering(context, acc, config, emit)
    run_turn(context, acc, config, emit)
  end

  defp run_turn(context, acc, config, emit) do
    case capture_hook_snapshot(@hook_snapshot_attempts) do
      {:ok, hook_snapshot} ->
        turn_config =
          config
          |> Support.resolve_turn_tools()
          |> Map.put(:hook_snapshot, hook_snapshot)

        with {:ok, context, turn_config} <- RunContext.reconcile_request(context, turn_config),
             {:ok, assistant, context, acc} <-
               run_assistant_turn(context, acc, turn_config, emit) do
          config = Map.put(turn_config, :tools, Map.get(config, :tools, :extensions))
          continue_after_assistant(assistant, context, acc, config, turn_config, emit)
        else
          {:error, reason} -> {:error, reason, context, acc}
        end

      {:error, reason} ->
        {:error, reason, context, acc}
    end
  end

  defp capture_hook_snapshot(0), do: Hooks.capture_snapshot()

  defp capture_hook_snapshot(attempts) do
    case Hooks.capture_snapshot() do
      {:error, :extension_runtime_recovering} ->
        with :ok <- Extensions.await_ready() do
          capture_hook_snapshot(attempts - 1)
        end

      result ->
        result
    end
  end

  defp run_assistant_turn(context, acc, turn_config, emit) do
    case Support.prepare_request(context, turn_config, emit, guard_options(turn_config)) do
      {:ok, prepared} ->
        emit.(%Event.TurnStart{})
        {assistant, context} = stream_assistant(prepared, turn_config, emit)
        {:ok, assistant, context, [assistant | acc]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A failed/aborted stream ends the run immediately (PI parity): no tool
  # execution, no per-turn hooks, and outer_loop won't drain follow-ups.
  defp continue_after_assistant(assistant, context, acc, config, turn_config, emit) do
    case assistant.stop_reason do
      stop when stop in [:error, :aborted] ->
        {context, acc} = finish_turn(context, acc, assistant, [], emit)
        {:halt, context, acc}

      _continue ->
        run_turn_tail(
          Message.tool_calls(assistant),
          assistant,
          context,
          acc,
          config,
          turn_config,
          emit
        )
    end
  end

  # Shared tail for tool and toolless turns: execute the batch (if any), emit
  # TurnEnd, run the per-turn hooks, then decide whether the loop lives on —
  # so prepare_next_turn/should_stop_after_turn see every turn, including the
  # natural stop (PI parity).
  defp run_turn_tail(tool_calls, assistant, context, acc, config, turn_config, emit) do
    {results, more_tool_calls?} = run_tools(tool_calls, assistant, turn_config, emit)
    {context, acc} = append_tool_results(context, acc, results, emit)
    {context, acc} = finish_turn(context, acc, assistant, results, emit)
    {context, config, hook_ctx} = prepare_next_turn_state(context, config, assistant, results)

    cond do
      # should_stop_after_turn is a hard stop: PI emits agent_end right away,
      # skipping the follow-up queue.
      Hooks.should_stop?(Map.put(hook_ctx, :context, context), turn_config.hook_snapshot) ->
        {:halt, context, acc}

      more_tool_calls? ->
        inner_loop(context, acc, config, emit)

      true ->
        steer_or_stop(context, acc, config, emit)
    end
  end

  defp run_tools([], _assistant, _turn_config, _emit), do: {[], false}

  defp run_tools(tool_calls, assistant, turn_config, emit) do
    {results, terminate?} = run_tool_batch(tool_calls, assistant, turn_config, emit)
    {results, not terminate?}
  end

  # A stopping turn (no tool calls, or a terminating batch) still re-checks
  # steering: a steer that arrived while the final turn streamed keeps the
  # inner loop alive (PI's `hasMoreToolCalls || pendingMessages.length > 0`)
  # instead of sitting queued until the next prompt.
  defp steer_or_stop(context, acc, config, emit) do
    case drain(config[:get_steering]) do
      [] ->
        {:stop, context, acc, config}

      msgs ->
        {context, acc} = append_steering(context, acc, msgs, emit)
        run_turn(context, acc, config, emit)
    end
  end

  defp run_tool_batch(tool_calls, assistant, turn_config, emit) do
    # Make the assistant message that issued the calls available to before_tool_call hooks.
    batch_config = Map.put(turn_config, :assistant, assistant)

    ToolRunner.run_batch_with_index(tool_calls, turn_config.tool_index, batch_config, emit)
  end

  defp append_tool_results(context, acc, results, emit) do
    Enum.each(results, fn result -> emit.(%Event.MessageEnd{message: result}) end)

    {append_messages(context, results), Enum.reverse(results, acc)}
  end

  defp finish_turn(context, acc, assistant, tool_results, emit) do
    emit.(%Event.TurnEnd{message: assistant, tool_results: tool_results})

    {context, acc}
  end

  defp prepare_next_turn_state(context, config, assistant, tool_results) do
    # Hooks may swap the context/model for the next turn, or force a stop.
    hook_ctx = %{assistant: assistant, tool_results: tool_results, cwd: config.cwd}

    {context, hooked} =
      Hooks.prepare_next_turn(context, config, hook_ctx, Map.fetch!(config, :hook_snapshot))

    config =
      hooked
      |> retarget_tool_source(config)
      |> Map.put(:tool_profile, config.tool_profile)

    {context, config, hook_ctx}
  end

  # A hook that changes `:tools` supplies a NEW selector for the next turn; the
  # retained `:tool_source` must follow it, or `Support.resolve_turn_tools/1`
  # keeps resolving the stale source and the hook's change never applies.
  defp retarget_tool_source(hooked, config) do
    if Map.get(hooked, :tools) == Map.get(config, :tools),
      do: hooked,
      else: Map.put(hooked, :tool_source, Map.get(hooked, :tools, :extensions))
  end

  defp stream_assistant(context, config, emit) do
    model = config.model
    llm_ctx = context.llm_context

    emit.(%Event.MessageStart{message: empty_assistant(model)})

    assistant =
      Support.request_provider(model, llm_ctx, config, emit, guard: false)
      |> normalize_assistant_response(model)
      |> Support.attach_context_digest(model, llm_ctx, config)

    emit.(%Event.MessageEnd{message: assistant})
    Support.emit_anchor_status(assistant, context.status, emit, model)
    {assistant, append_messages(context.context, [assistant])}
  end

  defp normalize_assistant_response({:ok, %Message.Assistant{} = assistant}, _model) do
    assistant
  end

  defp normalize_assistant_response({:error, reason}, model) do
    %Message.Assistant{
      content: Content.text("provider error: #{inspect(reason)}"),
      model: model_id(model),
      stop_reason: :error,
      error_message: inspect(reason),
      timestamp: Message.now()
    }
  end

  defp guard_options(config) do
    %{
      register_resource: Map.get(config, :register_resource),
      persist_event: Map.get(config, :persist_event),
      session_id: config |> Map.get(:opts, []) |> Keyword.get(:session_id),
      cwd: Map.get(config, :cwd)
    }
  end

  defp append_messages(context, messages) do
    %{context | messages: context.messages ++ messages}
  end

  defp inject_steering(context, acc, config, emit) do
    case drain(config[:get_steering]) do
      [] -> {context, acc}
      msgs -> append_steering(context, acc, msgs, emit)
    end
  end

  defp append_steering(context, acc, msgs, emit) do
    Enum.each(msgs, fn m -> emit.(%Event.MessageEnd{message: m}) end)
    {%{context | messages: context.messages ++ msgs}, Enum.reverse(msgs, acc)}
  end

  defp empty_assistant(model) do
    %Message.Assistant{
      content: [],
      model: model_id(model),
      stop_reason: :stop,
      timestamp: Message.now()
    }
  end

  defp model_id(nil), do: nil
  defp model_id(model), do: model.id

  defp drain(nil), do: []
  defp drain(fun) when is_function(fun, 0), do: fun.() || []
end
