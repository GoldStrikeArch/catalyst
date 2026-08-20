defmodule Catalyst.ACP.Workflow do
  @moduledoc """
  Providerless Catalyst workflow backed by a configured ACP v1 agent.

  The external agent owns its model loop and tools. Catalyst persists the user,
  assistant, and mirrored tool messages while forwarding streamed updates
  through the ordinary agent event contract.
  """

  @behaviour Catalyst.Workflow

  alias Catalyst.ACP
  alias Catalyst.ACP.{Agent, Client}
  alias Catalyst.Agent.Event
  alias Catalyst.Content
  alias Catalyst.Content.{Text, Thinking, ToolCall}
  alias Catalyst.LLM.Event, as: LLMEvent
  alias Catalyst.Message
  alias Catalyst.Workflow.Support

  @default_timeout 30 * 60 * 1_000

  @impl true
  def provider_required?, do: false

  @impl true
  def run(prompts, context, config, emit) do
    emit = Support.observed_emit(emit, config)
    emit.(%Event.AgentStart{})

    with {:ok, agent} <- resolve_agent(config),
         {:ok, session_meta} <- Agent.session_meta(agent, config),
         {:ok, client} <-
           ACP.Supervisor.client(
             session_id(config),
             agent,
             config.cwd,
             client_options(context, agent, config, session_meta)
           ),
         {:ok, acc} <- run_prompts(prompts, [], client, agent, config, emit),
         {:ok, acc} <- run_follow_ups(acc, client, agent, config, emit) do
      messages = Enum.reverse(acc)
      emit.(%Event.AgentEnd{messages: messages})
      {:ok, messages, %{context | messages: context.messages ++ messages}}
    end
  end

  defp run_follow_ups(acc, client, agent, config, emit) do
    case drain(config[:get_follow_up]) do
      [] ->
        {:ok, acc}

      prompts ->
        with {:ok, acc} <- run_prompts(prompts, acc, client, agent, config, emit) do
          run_follow_ups(acc, client, agent, config, emit)
        end
    end
  end

  defp run_prompts([], acc, _client, _agent, _config, _emit), do: {:ok, acc}

  defp run_prompts([%Message.User{} = prompt | rest], acc, client, agent, config, emit) do
    emit.(%Event.MessageEnd{message: prompt})

    with {:ok, text} <- prompt_text(prompt),
         {:ok, ref} <- Client.prompt(client, text),
         {:ok, mapped} <- await_prompt(client, ref, agent, config, emit) do
      acc = Enum.reduce(mapped, [prompt | acc], fn message, messages -> [message | messages] end)
      run_prompts(rest, acc, client, agent, config, emit)
    end
  end

  defp await_prompt(client, ref, agent, config, emit) do
    timeout = Keyword.get(config.opts, :acp_prompt_timeout, @default_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout
    state = new_mapper(agent, emit)
    await_update(client, ref, state, deadline)
  end

  defp await_update(client, ref, state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {Client, ^ref, {:update, update}} ->
        state = map_update(update, state)
        await_update(client, ref, state, deadline)

      {Client, ^ref, {:result, result}} ->
        finish_prompt(result, state)

      {Client, ^ref, {:error, reason}} ->
        {:error, reason}
    after
      remaining ->
        Client.cancel(client, ref)
        {:error, :prompt_timeout}
    end
  end

  defp new_mapper(agent, emit) do
    %{
      agent: agent,
      emit: emit,
      open?: false,
      content: [],
      messages: [],
      tools: %{}
    }
  end

  defp map_update(%{"sessionUpdate" => "agent_message_chunk", "content" => content}, state),
    do: append_chunk(state, :text, content_text(content))

  defp map_update(%{"sessionUpdate" => "agent_thought_chunk", "content" => content}, state),
    do: append_chunk(state, :thinking, content_text(content))

  defp map_update(%{"sessionUpdate" => "tool_call"} = update, state),
    do: start_tool(state, update)

  defp map_update(%{"sessionUpdate" => "tool_call_update"} = update, state),
    do: update_tool(state, update)

  defp map_update(_unknown, state), do: state

  defp append_chunk(state, _kind, ""), do: state

  defp append_chunk(state, kind, text) do
    state = ensure_open(state)

    llm_event =
      case kind do
        :text -> %LLMEvent.TextDelta{delta: text}
        :thinking -> %LLMEvent.ThinkingDelta{delta: text}
      end

    state.emit.(%Event.MessageUpdate{llm_event: llm_event})
    %{state | content: append_content(state.content, kind, text)}
  end

  defp start_tool(state, %{"toolCallId" => id} = update) when is_binary(id) do
    state = ensure_open(state)
    name = tool_name(update)
    args = Map.get(update, "rawInput", %{})
    call = %ToolCall{id: id, name: name, arguments: valid_args(args)}
    state = %{state | content: [call | state.content]}
    state = finalize_open(state, :tool_use, nil, nil)

    state.emit.(%Event.ToolExecutionStart{call_id: id, name: name, args: valid_args(args)})
    %{state | tools: Map.put(state.tools, id, %{name: name, args: valid_args(args)})}
  end

  defp start_tool(state, _invalid), do: state

  defp update_tool(state, %{"toolCallId" => id} = update) when is_binary(id) do
    case Map.fetch(state.tools, id) do
      {:ok, tool} -> apply_tool_update(state, id, tool, update)
      :error -> state
    end
  end

  defp update_tool(state, _invalid), do: state

  defp apply_tool_update(state, id, tool, %{"status" => status} = update)
       when status in ["completed", "failed"] do
    text = tool_content(update)
    error? = status == "failed"

    state.emit.(%Event.ToolExecutionEnd{
      call_id: id,
      name: tool.name,
      result: %{content: Content.text(text), details: %{}},
      is_error: error?
    })

    message = %Message.ToolResult{
      tool_call_id: id,
      tool_name: tool.name,
      content: Content.text(text),
      details: %{},
      is_error: error?,
      timestamp: Message.now()
    }

    state.emit.(%Event.MessageEnd{message: message})
    %{state | messages: [message | state.messages], tools: Map.delete(state.tools, id)}
  end

  defp apply_tool_update(state, id, tool, update) do
    partial = tool_content(update)

    case partial do
      "" ->
        state

      _text ->
        state.emit.(%Event.ToolExecutionUpdate{
          call_id: id,
          name: tool.name,
          args: tool.args,
          partial: partial
        })

        state
    end
  end

  defp finish_prompt(
         %{"stopReason" => reason, "sessionId" => response_id},
         state
       )
       when is_binary(reason) and is_binary(response_id) do
    {stop_reason, error} = stop_reason(reason)
    state = complete_open_tools(state, stop_reason)
    state = state |> ensure_open() |> finalize_open(stop_reason, response_id, error)
    {:ok, Enum.reverse(state.messages)}
  end

  defp finish_prompt(result, _state), do: {:error, {:invalid_prompt_result, result}}

  defp complete_open_tools(state, stop_reason) do
    Enum.reduce(state.tools, state, fn {id, tool}, acc ->
      error? = stop_reason != :stop
      text = "ACP prompt ended before the tool reported a terminal status."

      acc.emit.(%Event.ToolExecutionEnd{
        call_id: id,
        name: tool.name,
        result: %{content: Content.text(text), details: %{}},
        is_error: error?
      })

      message = %Message.ToolResult{
        tool_call_id: id,
        tool_name: tool.name,
        content: Content.text(text),
        details: %{},
        is_error: error?,
        timestamp: Message.now()
      }

      acc.emit.(%Event.MessageEnd{message: message})
      %{acc | messages: [message | acc.messages]}
    end)
    |> Map.put(:tools, %{})
  end

  defp ensure_open(%{open?: true} = state), do: state

  defp ensure_open(state) do
    state.emit.(%Event.MessageStart{message: assistant(state, [], :stop, nil, nil)})
    %{state | open?: true, content: []}
  end

  defp finalize_open(state, reason, response_id, error) do
    message = assistant(state, materialize(state.content), reason, response_id, error)
    state.emit.(%Event.MessageEnd{message: message})
    %{state | open?: false, content: [], messages: [message | state.messages]}
  end

  defp assistant(state, content, reason, response_id, error) do
    %Message.Assistant{
      content: content,
      api: "acp",
      provider: state.agent.id,
      stop_reason: reason,
      error_message: error,
      response_id: response_id,
      timestamp: Message.now()
    }
  end

  defp append_content([{:chunk, kind, chunks} | rest], kind, text),
    do: [{:chunk, kind, [text | chunks]} | rest]

  defp append_content(content, kind, text), do: [{:chunk, kind, [text]} | content]

  defp materialize(content) do
    content
    |> Enum.reverse()
    |> Enum.map(fn
      {:chunk, :text, chunks} ->
        %Text{text: chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:chunk, :thinking, chunks} ->
        %Thinking{thinking: chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      block ->
        block
    end)
  end

  defp tool_name(update) do
    case Map.get(update, "kind") || Map.get(update, "title") do
      name when is_binary(name) and byte_size(name) > 0 -> name
      _unknown -> "tool"
    end
  end

  defp valid_args(args) when is_map(args), do: args
  defp valid_args(_args), do: %{}

  defp content_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp content_text(_content), do: ""

  defp tool_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "content", "content" => block} -> content_text(block)
      %{"type" => "diff", "path" => path} when is_binary(path) -> "Updated #{path}"
      _unknown -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp tool_content(_update), do: ""

  defp stop_reason("end_turn"), do: {:stop, nil}
  defp stop_reason("max_tokens"), do: {:length, nil}
  defp stop_reason("max_turn_requests"), do: {:length, nil}
  defp stop_reason("cancelled"), do: {:aborted, "ACP prompt cancelled."}
  defp stop_reason("refusal"), do: {:error, "ACP agent refused the prompt."}
  defp stop_reason(reason), do: {:error, "ACP agent stopped with #{reason}."}

  defp prompt_text(%Message.User{content: content}) do
    case Enum.all?(content, &match?(%Text{}, &1)) do
      true -> {:ok, Content.text_of(content)}
      false -> {:error, :unsupported_prompt_content}
    end
  end

  defp resolve_agent(%{opts: opts, workflow: workflow}) do
    case Keyword.get(opts, :acp_agent) do
      %Agent{} = agent -> {:ok, agent}
      agent when is_map(agent) -> Agent.new(agent)
      nil -> resolve_configured_agent(workflow.name)
      invalid -> {:error, {:invalid_acp_agent, invalid}}
    end
  end

  defp resolve_configured_agent("acp/" <> id) when id != "", do: Agent.fetch(id)
  defp resolve_configured_agent(name), do: {:error, {:invalid_acp_workflow, name}}

  defp client_options(context, agent, config, session_meta) do
    [
      resume_id: continuation_id(context.messages, agent.id),
      session_meta: session_meta,
      cancel_timeout: Keyword.get(config.opts, :acp_cancel_timeout, 2_000)
    ]
  end

  defp continuation_id(messages, agent_id) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message.Assistant{
        api: "acp",
        provider: ^agent_id,
        response_id: response_id
      }
      when is_binary(response_id) and byte_size(response_id) > 0 ->
        response_id

      _message ->
        nil
    end)
  end

  defp session_id(config), do: Keyword.fetch!(config.opts, :session_id)

  defp drain(fun) when is_function(fun, 0), do: fun.()
  defp drain(_fun), do: []
end
