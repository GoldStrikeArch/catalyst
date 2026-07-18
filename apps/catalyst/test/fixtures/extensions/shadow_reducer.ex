defmodule Catalyst.Session.Reducer do
  @moduledoc false

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message}
  alias Catalyst.LLM

  @doc false
  def reduce(%Event.MessageEnd{message: message}, state) do
    message = mark(message)

    %{
      state
      | messages: [message | state.messages],
        in_flight: drop_in_flight(state.in_flight, message),
        error_message: error_of(message) || state.error_message
    }
    |> clear_streaming(message)
  end

  def reduce(%Event.MessageStart{message: message}, state),
    do: %{state | streaming_message: message, streaming_text: [], streaming_thinking: []}

  def reduce(%Event.MessageUpdate{llm_event: %LLM.Event.TextDelta{delta: delta}}, state),
    do: %{state | streaming_text: [delta | state.streaming_text]}

  def reduce(%Event.MessageUpdate{llm_event: %LLM.Event.ThinkingDelta{delta: delta}}, state),
    do: %{state | streaming_thinking: [delta | state.streaming_thinking]}

  def reduce(%Event.ToolExecutionStart{call_id: id}, state),
    do: %{state | pending_tool_calls: MapSet.put(state.pending_tool_calls, id)}

  def reduce(%Event.ToolExecutionEnd{call_id: id}, state),
    do: %{state | pending_tool_calls: MapSet.delete(state.pending_tool_calls, id)}

  def reduce(%Event.AgentEnd{}, state), do: %{state | in_flight: []}
  def reduce(_event, state), do: state

  @doc false
  def aborted_tool_results(state, reason) do
    text = aborted_text(reason)

    state.messages
    |> orphaned_tool_calls()
    |> Enum.map(fn %Content.ToolCall{id: id, name: name} ->
      %Message.ToolResult{
        tool_call_id: id,
        tool_name: name,
        content: Content.text(text),
        is_error: true,
        timestamp: Message.now()
      }
    end)
  end

  @doc false
  def failure_message(state, reason) do
    {text, stop_reason} = failure(reason)

    %Message.Assistant{
      content: Content.text(text),
      model: state.model && state.model.id,
      stop_reason: stop_reason,
      error_message: text,
      timestamp: Message.now()
    }
  end

  defp mark(%Message.Assistant{} = message) do
    %{message | content: Content.text("[shadow-reducer] ") ++ message.content}
  end

  defp mark(message), do: message

  defp clear_streaming(state, %Message.Assistant{}),
    do: %{state | streaming_message: nil, streaming_text: [], streaming_thinking: []}

  defp clear_streaming(state, _message), do: state

  defp error_of(%Message.Assistant{stop_reason: :error, error_message: error}), do: error
  defp error_of(_message), do: nil

  defp drop_in_flight([], _message), do: []
  defp drop_in_flight([{_kind, message} | rest], message), do: rest
  defp drop_in_flight([entry | rest], message), do: [entry | drop_in_flight(rest, message)]

  defp aborted_text(:killed), do: "Tool execution aborted."

  defp aborted_text(:interrupted),
    do: "Tool execution interrupted: the session stopped before the tool finished."

  defp aborted_text(_reason),
    do: "Tool execution failed: the run crashed before the tool finished."

  defp orphaned_tool_calls(messages), do: collect_orphans(messages, %{})

  defp collect_orphans([%Message.ToolResult{tool_call_id: id} | rest], seen),
    do: collect_orphans(rest, Map.put(seen, id, true))

  defp collect_orphans([%Message.Assistant{} = assistant | _rest], seen),
    do: Enum.reject(Message.tool_calls(assistant), &Map.has_key?(seen, &1.id))

  defp collect_orphans(_other, _seen), do: []

  defp failure(:killed), do: {"Run aborted.", :aborted}

  defp failure(reason) do
    {"Run failed: #{inspect(reason, limit: 50, printable_limit: 2_000)}", :error}
  end
end
