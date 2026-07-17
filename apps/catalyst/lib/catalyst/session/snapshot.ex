defmodule Catalyst.Session.Snapshot do
  @moduledoc """
  Builds the read-only state snapshot returned by `Catalyst.Session.Server.state/1`
  (consumed by the LiveView/CLI). Extracted so the projection can be hot-reloaded.
  """

  @doc "Project the session state into the snapshot map used by subscribers."
  def of(state) do
    %{
      id: state.id,
      cwd: state.cwd,
      messages: state.messages,
      streaming_message: state.streaming_message,
      pending_tool_calls: MapSet.to_list(state.pending_tool_calls),
      running: state.run != nil,
      model: state.model,
      system_prompt: state.system_prompt,
      store_path: state.store.path,
      error_message: state.error_message
    }
  end
end
