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

  @impl true
  def snapshot(%EngineState{} = state), do: {:ok, %{version: 1, payload: state}}

  @impl true
  def restore(%{version: 1, payload: %EngineState{schema_version: 1} = state}), do: {:ok, state}

  def restore(snapshot), do: {:error, {:unsupported_session_engine_snapshot, snapshot}}
end
