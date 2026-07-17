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
      messages: Enum.reverse(state.messages),
      streaming_message: project_streaming(state),
      pending_tool_calls: MapSet.to_list(state.pending_tool_calls),
      running: state.run != nil,
      model: state.model,
      # Session run opts (reasoning effort, service tier, transport, ...) so a
      # reattaching UI can restore its controls.
      opts: state.opts || [],
      system_prompt: state.system_prompt,
      store_path: state.store.path,
      error_message: state.error_message
    }
  end

  defp project_streaming(%{streaming_message: nil}), do: nil

  defp project_streaming(state) do
    thinking = IO.iodata_to_binary(state.streaming_thinking)
    text = IO.iodata_to_binary(state.streaming_text)

    blocks =
      [
        thinking != "" && %Content.Thinking{thinking: thinking},
        text != "" && %Content.Text{text: text}
      ]
      |> Enum.filter(& &1)

    %{state.streaming_message | content: blocks}
  end
end
