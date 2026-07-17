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

  alias Catalyst.Agent.{Event, ToolRunner}
  alias Catalyst.{Content, Hooks, Message}
  alias Catalyst.LLM
  alias Catalyst.Tools.Registry

  @doc "Run the loop for the given prompts. Returns `{:ok, new_messages, final_context}`."
  @spec run([Message.t()], map(), map(), (Event.t() -> any())) :: {:ok, [Message.t()], map()}
  def run(prompts, context, config, emit) do
    # Every event is also offered to registered observers (Hooks `on/1`), isolated.
    emit = fn ev ->
      Hooks.notify(ev)
      emit.(ev)
    end

    emit.(%Event.AgentStart{})

    # User prompts flow through message_end like everything else, so the single
    # writer (Session.Server) appends/persists them uniformly.
    Enum.each(prompts, fn p -> emit.(%Event.MessageEnd{message: p}) end)
    context = %{context | messages: context.messages ++ prompts}

    # `acc` is carried NEWEST-FIRST (O(1) appends) and reversed once here.
    # `context.messages` stays chronological: its batch appends are O(n) per
    # turn, which the per-turn LLM request building costs anyway.
    {context, acc} = outer_loop(context, Enum.reverse(prompts), config, emit)
    new_messages = Enum.reverse(acc)

    emit.(%Event.AgentEnd{messages: new_messages})
    {:ok, new_messages, context}
  end

  # Outer loop: after the inner loop reaches a natural stop, drain follow-ups.
  # A halted run (provider error/abort, or a should_stop_after_turn veto) skips
  # them — queued follow-ups wait for the next run instead of re-firing into a
  # failed provider.
  defp outer_loop(context, acc, config, emit) do
    case inner_loop(context, acc, config, emit) do
      {:halt, context, acc} ->
        {context, acc}

      {:stop, context, acc} ->
        case drain(config[:get_follow_up]) do
          [] ->
            {context, acc}

          follow ->
            Enum.each(follow, fn m -> emit.(%Event.MessageEnd{message: m}) end)
            context = %{context | messages: context.messages ++ follow}
            outer_loop(context, Enum.reverse(follow, acc), config, emit)
        end
    end
  end

  # Inner loop: stream a turn, run tools, repeat while tool calls (or steering
  # messages) remain. Returns `{:stop, ...}` on a natural stop (follow-ups may
  # re-enter) or `{:halt, ...}` on a hard stop (they may not).
  defp inner_loop(context, acc, config, emit) do
    {context, acc} = inject_steering(context, acc, config, emit)
    run_turn(context, acc, config, emit)
  end

  defp run_turn(context, acc, config, emit) do
    turn_config = resolve_turn_tools(config)
    {assistant, context, acc} = run_assistant_turn(context, acc, turn_config, emit)

    continue_after_assistant(assistant, context, acc, config, turn_config, emit)
  end

  defp resolve_turn_tools(config) do
    # Resolve the live tool set for THIS turn (re-resolved each turn, so a tool the
    # agent just created with develop_tool becomes callable on the next turn).
    Map.put(config, :tools, Catalyst.Extensions.resolve(config.tools))
  end

  defp run_assistant_turn(context, acc, turn_config, emit) do
    emit.(%Event.TurnStart{})
    {assistant, context} = stream_assistant(context, turn_config, emit)

    {assistant, context, [assistant | acc]}
  end

  defp continue_after_assistant(assistant, context, acc, config, turn_config, emit) do
    # A failed/aborted stream ends the run immediately (PI parity): no tool
    # execution, no per-turn hooks, and outer_loop won't drain follow-ups.
    if assistant.stop_reason in [:error, :aborted] do
      {context, acc} = finish_turn(context, acc, assistant, [], emit)
      {:halt, context, acc}
    else
      run_turn_tail(Message.tool_calls(assistant), assistant, context, acc, config, turn_config, emit)
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
      Hooks.should_stop?(Map.put(hook_ctx, :context, context)) ->
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
        {:stop, context, acc}

      msgs ->
        {context, acc} = append_steering(context, acc, msgs, emit)
        run_turn(context, acc, config, emit)
    end
  end

  defp run_tool_batch(tool_calls, assistant, turn_config, emit) do
    # Make the assistant message that issued the calls available to before_tool_call hooks.
    batch_config = Map.put(turn_config, :assistant, assistant)

    ToolRunner.run_batch(tool_calls, batch_config, emit)
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
    {context, config} = Hooks.prepare_next_turn(context, config, hook_ctx)

    {context, config, hook_ctx}
  end

  defp stream_assistant(context, config, emit) do
    model = config.model
    llm_ctx = build_llm_context(context, config)

    emit.(%Event.MessageStart{message: empty_assistant(model)})

    assistant =
      stream_provider(model, llm_ctx, config, emit)
      |> normalize_assistant_response(model)

    emit.(%Event.MessageEnd{message: assistant})
    {assistant, append_messages(context, [assistant])}
  end

  defp build_llm_context(context, config) do
    convert = config[:convert_to_llm] || (&Function.identity/1)

    # Hooks may rewrite/compact/redact the message list for THIS request only
    # (the stored context is untouched).
    messages = Hooks.transform_context(context.messages, %{config: config})

    %LLM.Context{
      system_prompt: context.system_prompt,
      messages: convert.(messages),
      tools: Registry.to_provider_tools(config.tools)
    }
  end

  defp stream_provider(model, llm_ctx, config, emit) do
    sink = fn ev -> emit.(%Event.MessageUpdate{llm_event: ev}) end

    config.provider.stream(model, llm_ctx, config[:opts] || [], sink)
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
