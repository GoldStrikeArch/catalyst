defmodule Catalyst.Test.SessionEngineRejectRestore do
  @moduledoc false

  @behaviour Catalyst.Contracts.SessionEngine.V1

  alias Catalyst.Session.DefaultEngine

  @impl true
  defdelegate event(envelope, state), to: DefaultEngine

  @impl true
  defdelegate aborted_tool_results(state, reason), to: DefaultEngine

  @impl true
  defdelegate failure_message(state, reason), to: DefaultEngine

  @impl true
  defdelegate snapshot(state), to: DefaultEngine

  @impl true
  def restore(_snapshot), do: {:error, :restore_rejected}
end
