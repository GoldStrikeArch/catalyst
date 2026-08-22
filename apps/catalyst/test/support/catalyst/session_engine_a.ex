defmodule Catalyst.Test.SessionEngineA do
  @moduledoc false

  @behaviour Catalyst.Contracts.SessionEngine.V1

  alias Catalyst.Session.{DefaultEngine, EngineState, EventEnvelope}

  @impl true
  def event(%EventEnvelope{} = envelope, %EngineState{} = state) do
    envelope
    |> DefaultEngine.event(state)
    |> Map.put(:error_message, "session-engine-a")
  end

  @impl true
  defdelegate aborted_tool_results(state, reason), to: DefaultEngine

  @impl true
  defdelegate failure_message(state, reason), to: DefaultEngine

  @impl true
  defdelegate snapshot(state), to: DefaultEngine

  @impl true
  defdelegate restore(snapshot), to: DefaultEngine
end
