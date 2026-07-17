defmodule Catalyst.Session.Reducer do
  @moduledoc """
  Pure event-folding for `Catalyst.Session.Server` (PI's `processEvents`). Kept out
  of the GenServer so the folding logic can be hot-reloaded without restarting live
  sessions — reloading this module changes how events fold on the very next event.

  Persistence is NOT done here — `Session.Server` appends to the store alongside
  logging/broadcasting, keeping this fold side-effect free.
  """

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message}
  alias Catalyst.LLM

  @doc "Fold one agent event into the session state. `state.messages` is newest-first."
  def reduce(%Event.MessageEnd{message: m}, state) do
    %{
      state
      | messages: [m | state.messages],
        in_flight: drop_in_flight(state.in_flight, m),
        error_message: error_of(m) || state.error_message
    }
    |> clear_streaming(m)
  end

  def reduce(%Event.MessageStart{message: m}, state),
    do: %{state | streaming_message: m, streaming_text: [], streaming_thinking: []}

  # Accumulate streamed deltas (as iodata) so a reattaching UI can rebuild the
  # in-flight bubble from the snapshot instead of losing already-streamed text.
  def reduce(%Event.MessageUpdate{llm_event: %LLM.Event.TextDelta{delta: d}}, state),
    do: %{state | streaming_text: [state.streaming_text | d]}

  def reduce(%Event.MessageUpdate{llm_event: %LLM.Event.ThinkingDelta{delta: d}}, state),
    do: %{state | streaming_thinking: [state.streaming_thinking | d]}

  def reduce(%Event.ToolExecutionStart{call_id: id}, state),
    do: %{state | pending_tool_calls: MapSet.put(state.pending_tool_calls, id)}

  def reduce(%Event.ToolExecutionEnd{call_id: id}, state),
    do: %{state | pending_tool_calls: MapSet.delete(state.pending_tool_calls, id)}

  # A clean run end: everything drained was delivered (or folded above).
  def reduce(%Event.AgentEnd{}, state), do: %{state | in_flight: []}

  def reduce(_event, state), do: state

  defp clear_streaming(state, %Message.Assistant{}),
    do: %{state | streaming_message: nil, streaming_text: [], streaming_thinking: []}

  defp clear_streaming(state, _message), do: state

  # Surface provider failures (assistant turns with stop_reason :error) in the
  # snapshot's error_message — they are not run crashes, so handle_failure
  # never sees them.
  defp error_of(%Message.Assistant{stop_reason: :error, error_message: e}), do: e
  defp error_of(_message), do: nil

  # Remove the first in-flight entry whose message was just folded.
  defp drop_in_flight([], _m), do: []
  defp drop_in_flight([{_kind, m} | rest], m), do: rest
  defp drop_in_flight([entry | rest], m), do: [entry | drop_in_flight(rest, m)]

  @doc """
  Synthesized error ToolResults for tool calls orphaned by a run failure/abort.

  An abort/crash can land after the assistant message carrying tool calls was
  folded and persisted but before its results were. Providers reject a replayed
  transcript that has a tool call with no output, so every subsequent request
  for the session would fail — these results keep the transcript replayable.
  """
  def aborted_tool_results(state, reason) do
    text =
      case reason do
        :killed ->
          "Tool execution aborted."

        :interrupted ->
          "Tool execution interrupted: the session stopped before the tool finished."

        _other ->
          "Tool execution failed: the run crashed before the tool finished."
      end

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

  # Tool calls of the most recent assistant message that have no ToolResult.
  # `messages` is newest-first; results always directly follow their assistant
  # message, so anything other than a ToolResult before the first Assistant
  # means the last tool batch (if any) completed.
  defp orphaned_tool_calls(messages), do: collect_orphans(messages, %{})

  defp collect_orphans([%Message.ToolResult{tool_call_id: id} | rest], seen),
    do: collect_orphans(rest, Map.put(seen, id, true))

  defp collect_orphans([%Message.Assistant{} = a | _rest], seen),
    do: Enum.reject(Message.tool_calls(a), &Map.has_key?(seen, &1.id))

  defp collect_orphans(_other, _seen), do: []

  @doc "Build the synthesized assistant message for a run failure/abort."
  def failure_message(state, reason) do
    {text, stop} =
      case reason do
        :killed ->
          {"Run aborted.", :aborted}

        other ->
          # Bounded inspect: a crash reason can embed large terms (e.g. the full
          # message history in a clause error), and this text is persisted and
          # replayed to the LLM in every subsequent request.
          {"Run failed: #{inspect(other, limit: 50, printable_limit: 2_000)}", :error}
      end

    %Message.Assistant{
      content: Content.text(text),
      model: state.model && state.model.id,
      stop_reason: stop,
      error_message: text,
      timestamp: Message.now()
    }
  end
end
