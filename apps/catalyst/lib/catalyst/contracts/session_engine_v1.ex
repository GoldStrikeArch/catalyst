defmodule Catalyst.Contracts.SessionEngine.V1 do
  @moduledoc """
  Version-one contract for session-bound event semantics.

  The stable `Catalyst.Session.Server` host retains command handling, task
  ownership, persistence, and PubSub delivery. A session engine owns the pure
  state transition for accepted agent events plus failure transcript repair.
  """

  alias Catalyst.Message
  alias Catalyst.Runtime.ContractRef
  alias Catalyst.Session.{EngineState, EventEnvelope}

  @doc "Fold one accepted event into the engine-owned session state."
  @callback event(EventEnvelope.t(), EngineState.t()) :: EngineState.t()

  @doc "Build repair results for tool calls orphaned by an interrupted run."
  @callback aborted_tool_results(EngineState.t(), term()) :: [Message.ToolResult.t()]

  @doc "Build the terminal assistant message for a failed or aborted run."
  @callback failure_message(EngineState.t(), term()) :: Message.Assistant.t()

  @doc "Return the stable Runtime Graph contract reference."
  @spec ref() :: ContractRef.t()
  def ref, do: ContractRef.new!("catalyst.session-engine", 1)
end
