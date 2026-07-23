defmodule Catalyst.Session.Snapshot do
  @moduledoc """
  Builds the read-only state snapshot returned by `Catalyst.Session.Server.state/1`
  (consumed by the LiveView/CLI). Extracted so the projection can be hot-reloaded.
  """

  alias Catalyst.Content

  @doc """
  Project the session state into the snapshot map used by subscribers.
  `messages` come out chronological (state stores them newest-first);
  `streaming_message` carries the deltas streamed so far as content blocks, so
  a reattaching UI can rebuild the in-flight bubble.
  """
  @spec of(map()) :: map()
  def of(state) do
    %{
      id: state.id,
      cwd: state.cwd,
      parent_id: state.parent_id,
      root_session_id: state.root_session_id,
      agent_depth: state.agent_depth,
      messages: Enum.reverse(state.messages),
      streaming_message: project_streaming(state),
      pending_tool_calls: MapSet.to_list(state.pending_tool_calls),
      running: state.run != nil,
      model: state.model,
      # Session run opts (reasoning effort, service tier, transport, ...) so a
      # reattaching UI can restore its controls.
      opts: state.opts || [],
      system_prompt: state.system_prompt,
      run_metadata: visible_run_metadata(state),
      store_path: state.store.path,
      error_message: state.error_message
    }
  end

  defp visible_run_metadata(%{
         run: run,
         agent_ended: true,
         run_final_assistant: %Catalyst.Message.Assistant{stop_reason: reason},
         current_run_metadata: current
       })
       when not is_nil(run) and reason not in [:error, :aborted],
       do: current

  defp visible_run_metadata(%{run: run, agent_ended: true} = state) when not is_nil(run),
    do: state.last_successful_run_metadata

  defp visible_run_metadata(%{run: run, current_run_metadata: current}) when not is_nil(run),
    do: current

  defp visible_run_metadata(state), do: state.last_successful_run_metadata

  defp project_streaming(%{streaming_message: nil}), do: nil

  defp project_streaming(state) do
    thinking = streaming_binary(state.streaming_thinking)
    text = streaming_binary(state.streaming_text)

    blocks =
      [
        thinking != "" && %Content.Thinking{thinking: thinking},
        text != "" && %Content.Text{text: text}
      ]
      |> Enum.filter(& &1)

    %{state.streaming_message | content: blocks}
  end

  # Reducers keep a proper newest-first chunk list; reverse once here.
  defp streaming_binary(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()
end
