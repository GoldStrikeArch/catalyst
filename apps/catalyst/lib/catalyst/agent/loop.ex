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

    {context, new_messages} = outer_loop(context, prompts, config, emit)

    emit.(%Event.AgentEnd{messages: new_messages})
    {:ok, new_messages, context}
  end

  # Outer loop: after the inner loop reaches a natural stop, drain follow-ups.
  defp outer_loop(context, acc, config, emit) do
    {context, acc} = inner_loop(context, acc, config, emit)

    case drain(config[:get_follow_up]) do
      [] ->
        {context, acc}

      follow ->
        Enum.each(follow, fn m -> emit.(%Event.MessageEnd{message: m}) end)
        context = %{context | messages: context.messages ++ follow}
        outer_loop(context, acc ++ follow, config, emit)
    end
  end

  # Inner loop: stream a turn, run tools, repeat while tool calls remain.
  defp inner_loop(context, acc, config, emit) do
    {context, acc} = inject_steering(context, acc, config, emit)

    # Resolve the live tool set for THIS turn (re-resolved each turn, so a tool the
    # agent just created with develop_tool becomes callable on the next turn).
    turn_config = Map.put(config, :tools, Catalyst.Extensions.resolve(config.tools))

    emit.(%Event.TurnStart{})
    {assistant, context} = stream_assistant(context, turn_config, emit)
    acc = acc ++ [assistant]

    case Message.tool_calls(assistant) do
      [] ->
        emit.(%Event.TurnEnd{message: assistant, tool_results: []})
        {context, acc}

      tool_calls ->
        # Make the assistant message that issued the calls available to before_tool_call hooks.
        batch_config = Map.put(turn_config, :assistant, assistant)
        {results, terminate?} = ToolRunner.run_batch(tool_calls, batch_config, emit)
        Enum.each(results, fn r -> emit.(%Event.MessageEnd{message: r}) end)
        context = %{context | messages: context.messages ++ results}
        acc = acc ++ results
        emit.(%Event.TurnEnd{message: assistant, tool_results: results})

        # Hooks may swap the context/model for the next turn, or force a stop.
        hook_ctx = %{assistant: assistant, tool_results: results, cwd: config.cwd}
        {context, config} = Hooks.prepare_next_turn(context, config, hook_ctx)
        stop? = terminate? or Hooks.should_stop?(Map.put(hook_ctx, :context, context))

        if stop? do
          {context, acc}
        else
          inner_loop(context, acc, config, emit)
        end
    end
  end

  defp stream_assistant(context, config, emit) do
    model = config.model
    convert = config[:convert_to_llm] || (&Function.identity/1)

    # Hooks may rewrite/compact/redact the message list for THIS request only
    # (the stored context is untouched).
    messages = Hooks.transform_context(context.messages, %{config: config})

    llm_ctx = %LLM.Context{
      system_prompt: context.system_prompt,
      messages: convert.(messages),
      tools: Registry.to_provider_tools(config.tools)
    }

    emit.(%Event.MessageStart{message: empty_assistant(model)})
    sink = fn ev -> emit.(%Event.MessageUpdate{message: nil, llm_event: ev}) end

    assistant =
      case config.provider.stream(model, llm_ctx, config[:opts] || [], sink) do
        {:ok, %Message.Assistant{} = a} ->
          a

        {:error, reason} ->
          %Message.Assistant{
            content: Content.text("provider error: #{inspect(reason)}"),
            model: model && model.id,
            stop_reason: :error,
            error_message: inspect(reason),
            timestamp: Message.now()
          }
      end

    emit.(%Event.MessageEnd{message: assistant})
    {assistant, %{context | messages: context.messages ++ [assistant]}}
  end

  defp inject_steering(context, acc, config, emit) do
    case drain(config[:get_steering]) do
      [] ->
        {context, acc}

      msgs ->
        Enum.each(msgs, fn m -> emit.(%Event.MessageEnd{message: m}) end)
        {%{context | messages: context.messages ++ msgs}, acc ++ msgs}
    end
  end

  defp empty_assistant(model) do
    %Message.Assistant{
      content: [],
      model: model && model.id,
      stop_reason: :stop,
      timestamp: Message.now()
    }
  end

  defp drain(nil), do: []
  defp drain(fun) when is_function(fun, 0), do: fun.() || []
end
