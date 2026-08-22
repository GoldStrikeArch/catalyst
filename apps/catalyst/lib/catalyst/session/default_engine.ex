defmodule Catalyst.Session.DefaultEngine do
  @moduledoc """
  Default version-one session engine backed by the existing pure reducer.
  """

  @behaviour Catalyst.Contracts.SessionEngine.V1

  alias Catalyst.Session.{EngineState, EventEnvelope, Reducer}

  @impl true
  def event(%EventEnvelope{event: event}, %EngineState{} = state),
    do: Reducer.reduce(event, state)

  @impl true
  def aborted_tool_results(%EngineState{} = state, reason),
    do: Reducer.aborted_tool_results(state, reason)

  @impl true
  def failure_message(%EngineState{} = state, reason),
    do: Reducer.failure_message(state, reason)
end
