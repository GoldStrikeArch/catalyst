defmodule Catalyst.Session.Reducer do
  @moduledoc """
  Pure event-folding for `Catalyst.Session.Server` (PI's `processEvents`). Kept out
  of the GenServer so the folding logic can be hot-reloaded without restarting live
  sessions — reloading this module changes how events fold on the very next event.
  """

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message}
  alias Catalyst.Session.Store

  @doc "Fold one agent event into the session state."
  def reduce(%Event.MessageEnd{message: m}, state) do
    Store.append_message(state.store, m)
    streaming = if match?(%Message.Assistant{}, m), do: nil, else: state.streaming_message
    %{state | messages: state.messages ++ [m], streaming_message: streaming}
  end

  def reduce(%Event.MessageStart{message: m}, state), do: %{state | streaming_message: m}

  def reduce(%Event.ToolExecutionStart{call_id: id}, state),
    do: %{state | pending_tool_calls: MapSet.put(state.pending_tool_calls, id)}

  def reduce(%Event.ToolExecutionEnd{call_id: id}, state),
    do: %{state | pending_tool_calls: MapSet.delete(state.pending_tool_calls, id)}

  def reduce(_event, state), do: state

  @doc "Build the synthesized assistant message for a run failure/abort."
  def failure_message(state, reason) do
    {text, stop} =
      case reason do
        :killed -> {"Run aborted.", :aborted}
        other -> {"Run failed: #{inspect(other)}", :error}
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
