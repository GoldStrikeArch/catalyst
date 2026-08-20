defmodule Catalyst.ClaudeCode.Workflow do
  @moduledoc """
  Providerless workflow backed by one official `claude -p` process per prompt.

  Claude Code owns its model loop, context, tools, and compaction. Catalyst
  mirrors the documented stream into its existing events and transcript, then
  resumes later prompts with the persisted Claude session id.
  """

  @behaviour Catalyst.Workflow

  alias Catalyst.Agent.Event
  alias Catalyst.ClaudeCode.{Command, Process}
  alias Catalyst.Content
  alias Catalyst.Content.{Text, Thinking, ToolCall}
  alias Catalyst.LLM.Event, as: LLMEvent
  alias Catalyst.{Message, Usage}
  alias Catalyst.Workflow.Support

  @impl true
  def provider_required?, do: false

  @impl true
  def run(prompts, context, config, emit) do
    emit = Support.observed_emit(emit, config)
    emit.(%Event.AgentStart{})

    with {:ok, acc, messages} <- run_prompts(prompts, [], context.messages, config, emit),
         {:ok, acc, messages} <- run_follow_ups(acc, messages, config, emit) do
      new_messages = Enum.reverse(acc)
      emit.(%Event.AgentEnd{messages: new_messages})
      {:ok, new_messages, %{context | messages: messages}}
    end
  end

  defp run_follow_ups(acc, messages, config, emit) do
    case drain(config[:get_follow_up]) do
      [] ->
        {:ok, acc, messages}

      prompts ->
        with {:ok, acc, messages} <- run_prompts(prompts, acc, messages, config, emit) do
          run_follow_ups(acc, messages, config, emit)
        end
    end
  end

  defp run_prompts([], acc, messages, _config, _emit), do: {:ok, acc, messages}

  defp run_prompts([%Message.User{} = prompt | rest], acc, messages, config, emit) do
    emit.(%Event.MessageEnd{message: prompt})

    with {:ok, text} <- prompt_text(prompt),
         {:ok, command} <- Command.build(text, config, continuation_id(messages)),
         {:ok, mapped} <- run_command(command, config, emit) do
      acc = Enum.reduce(mapped, [prompt | acc], fn message, new -> [message | new] end)
      messages = messages ++ [prompt | mapped]
      run_prompts(rest, acc, messages, config, emit)
    end
  end

  defp run_command(command, config, emit) do
    initial = %{
      emit: emit,
      initialized?: false,
      terminal?: false,
      session_id: nil,
      model: nil,
      streaming?: false,
      messages: [],
      tools: %{},
      diagnostics: []
    }

    try do
      case Process.run(
             command,
             config.cwd,
             initial,
             &map_line/2,
             timeout: Keyword.get(config.opts, :claude_timeout, 30 * 60 * 1_000)
           ) do
        {:ok, %{terminal?: true, initialized?: true} = state, 0} ->
          {:ok, Enum.reverse(state.messages)}

        {:ok, %{terminal?: false} = state, status} ->
          {:error, {:missing_claude_result, status, diagnostics(state)}}

        {:ok, state, status} ->
          {:error, {:claude_exit, status, diagnostics(state)}}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Command.cleanup(command)
    end
  end

  defp map_line(line, state) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) -> {:ok, map_event(event, state)}
      {:ok, _invalid} -> {:error, :invalid_claude_event}
      {:error, _decode_error} -> {:ok, add_diagnostic(state, line)}
    end
  end

  defp map_event(%{"type" => "system", "subtype" => "init"} = event, state) do
    %{
      state
      | initialized?: true,
        session_id: binary(event["session_id"]) || state.session_id,
        model: binary(event["model"]) || state.model
    }
  end

  defp map_event(
         %{
           "type" => "stream_event",
           "event" => %{"type" => "content_block_delta", "delta" => delta}
         },
         state
       ) do
    map_delta(delta, state)
  end

  defp map_event(%{"type" => "assistant", "message" => message} = event, state)
       when is_map(message) do
    state = close_stream(state)
    session_id = binary(event["session_id"]) || state.session_id
    content = assistant_content(message["content"])

    assistant = %Message.Assistant{
      content: content,
      api: "claude-code",
      provider: "claude-code",
      model: binary(message["model"]) || state.model,
      usage: usage(message["usage"]),
      stop_reason: message_stop(message["stop_reason"], content),
      response_id: session_id,
      timestamp: Message.now()
    }

    state.emit.(%Event.MessageEnd{message: assistant})
    state = %{state | messages: [assistant | state.messages], session_id: session_id}
    start_tools(state, Content.tool_calls(content))
  end

  defp map_event(%{"type" => "user", "message" => %{"content" => content}}, state)
       when is_list(content) do
    Enum.reduce(content, state, &map_tool_result/2)
  end

  defp map_event(%{"type" => "result"} = event, state) do
    state = close_stream(state)
    session_id = binary(event["session_id"]) || state.session_id
    state = complete_tools(state, event)
    state = ensure_terminal_assistant(state, event, session_id)
    %{state | terminal?: true, session_id: session_id}
  end

  defp map_event(_unknown, state), do: state

  defp map_delta(%{"type" => "text_delta", "text" => text}, state) when is_binary(text) do
    state = ensure_stream(state)
    state.emit.(%Event.MessageUpdate{llm_event: %LLMEvent.TextDelta{delta: text}})
    state
  end

  defp map_delta(%{"type" => "thinking_delta", "thinking" => text}, state)
       when is_binary(text) do
    state = ensure_stream(state)
    state.emit.(%Event.MessageUpdate{llm_event: %LLMEvent.ThinkingDelta{delta: text}})
    state
  end

  defp map_delta(_delta, state), do: state

  defp ensure_stream(%{streaming?: true} = state), do: state

  defp ensure_stream(state) do
    message = %Message.Assistant{
      api: "claude-code",
      provider: "claude-code",
      model: state.model,
      response_id: state.session_id,
      timestamp: Message.now()
    }

    state.emit.(%Event.MessageStart{message: message})
    %{state | streaming?: true}
  end

  defp close_stream(%{streaming?: true} = state), do: %{state | streaming?: false}
  defp close_stream(state), do: state

  defp start_tools(state, calls) do
    Enum.reduce(calls, state, fn call, acc ->
      acc.emit.(%Event.ToolExecutionStart{
        call_id: call.id,
        name: call.name,
        args: call.arguments
      })

      %{acc | tools: Map.put(acc.tools, call.id, call)}
    end)
  end

  defp map_tool_result(%{"type" => "tool_result", "tool_use_id" => id} = result, state)
       when is_binary(id) do
    case Map.pop(state.tools, id) do
      {nil, _tools} ->
        state

      {%ToolCall{} = call, tools} ->
        text = tool_result_text(result["content"])
        error? = result["is_error"] == true

        state.emit.(%Event.ToolExecutionEnd{
          call_id: id,
          name: call.name,
          result: %{content: Content.text(text), details: %{}},
          is_error: error?
        })

        message = %Message.ToolResult{
          tool_call_id: id,
          tool_name: call.name,
          content: Content.text(text),
          details: %{},
          is_error: error?,
          timestamp: Message.now()
        }

        state.emit.(%Event.MessageEnd{message: message})
        %{state | tools: tools, messages: [message | state.messages]}
    end
  end

  defp map_tool_result(_content, state), do: state

  defp complete_tools(state, event) do
    Enum.reduce(state.tools, state, fn {id, call}, acc ->
      text = binary(event["result"]) || "Claude ended before the tool returned a result."

      acc.emit.(%Event.ToolExecutionEnd{
        call_id: id,
        name: call.name,
        result: %{content: Content.text(text), details: %{}},
        is_error: true
      })

      message = %Message.ToolResult{
        tool_call_id: id,
        tool_name: call.name,
        content: Content.text(text),
        details: %{},
        is_error: true,
        timestamp: Message.now()
      }

      acc.emit.(%Event.MessageEnd{message: message})
      %{acc | messages: [message | acc.messages]}
    end)
    |> Map.put(:tools, %{})
  end

  defp ensure_terminal_assistant(state, event, session_id) do
    case {event["is_error"], state.messages} do
      {true, [%Message.Assistant{stop_reason: :error} | _rest]} ->
        state

      {true, _messages} ->
        append_terminal_assistant(state, event, session_id, true)

      {_error, [%Message.Assistant{} | _rest]} ->
        state

      {_error, _no_final_assistant} ->
        append_terminal_assistant(state, event, session_id, false)
    end
  end

  defp append_terminal_assistant(state, event, session_id, error?) do
    text = binary(event["result"]) || result_error(event) || ""

    assistant = %Message.Assistant{
      content: Content.text(text),
      api: "claude-code",
      provider: "claude-code",
      model: state.model,
      usage: usage(event["usage"]),
      stop_reason: if(error?, do: :error, else: :stop),
      error_message: if(error?, do: text),
      response_id: session_id,
      timestamp: Message.now()
    }

    state.emit.(%Event.MessageEnd{message: assistant})
    %{state | messages: [assistant | state.messages]}
  end

  defp assistant_content(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        [%Text{text: text}]

      %{"type" => "thinking", "thinking" => thinking} when is_binary(thinking) ->
        [%Thinking{thinking: thinking}]

      %{"type" => "tool_use", "id" => id, "name" => name} = block
      when is_binary(id) and is_binary(name) ->
        [%ToolCall{id: id, name: name, arguments: valid_args(block["input"])}]

      _unknown ->
        []
    end)
  end

  defp assistant_content(_content), do: []

  defp tool_result_text(text) when is_binary(text), do: text

  defp tool_result_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _unknown -> []
    end)
    |> Enum.join("\n")
  end

  defp tool_result_text(_content), do: ""

  defp usage(usage) when is_map(usage) do
    input = integer(usage["input_tokens"])
    output = integer(usage["output_tokens"])
    cache_read = integer(usage["cache_read_input_tokens"])
    cache_write = integer(usage["cache_creation_input_tokens"])

    %Usage{
      input: input,
      output: output,
      cache_read: cache_read,
      cache_write: cache_write,
      total_tokens: input + output + cache_read + cache_write
    }
  end

  defp usage(_usage), do: nil

  defp message_stop("max_tokens", _content), do: :length

  defp message_stop(_reason, content),
    do: if(Content.tool_calls(content) == [], do: :stop, else: :tool_use)

  defp continuation_id(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message.Assistant{
        api: "claude-code",
        provider: "claude-code",
        response_id: id
      }
      when is_binary(id) and id != "" ->
        id

      _message ->
        nil
    end)
  end

  defp prompt_text(%Message.User{content: content}) do
    case Enum.all?(content, &match?(%Text{}, &1)) do
      true -> {:ok, Content.text_of(content)}
      false -> {:error, :unsupported_prompt_content}
    end
  end

  defp add_diagnostic(state, line) do
    diagnostic = String.slice(line, 0, 2_000)
    %{state | diagnostics: [diagnostic | Enum.take(state.diagnostics, 9)]}
  end

  defp diagnostics(state), do: state.diagnostics |> Enum.reverse() |> Enum.join("\n")

  defp result_error(%{"errors" => [error | _rest]}) when is_binary(error), do: error
  defp result_error(_event), do: nil

  defp valid_args(args) when is_map(args), do: args
  defp valid_args(_args), do: %{}

  defp binary(value) when is_binary(value) and value != "", do: value
  defp binary(_value), do: nil

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0

  defp drain(fun) when is_function(fun, 0), do: fun.()
  defp drain(_fun), do: []
end
