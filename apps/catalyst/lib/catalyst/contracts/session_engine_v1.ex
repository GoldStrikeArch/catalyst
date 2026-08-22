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

  @typedoc "Versioned, process-local state capsule used during an active-session handoff."
  @type snapshot :: %{version: pos_integer(), payload: term()}

  @doc "Fold one accepted event into the engine-owned session state."
  @callback event(EventEnvelope.t(), EngineState.t()) :: EngineState.t()

  @doc "Build repair results for tool calls orphaned by an interrupted run."
  @callback aborted_tool_results(EngineState.t(), term()) :: [Message.ToolResult.t()]

  @doc "Build the terminal assistant message for a failed or aborted run."
  @callback failure_message(EngineState.t(), term()) :: Message.Assistant.t()

  @doc "Snapshot the complete engine-owned state while the session is quiescent."
  @callback snapshot(EngineState.t()) :: {:ok, snapshot()} | {:error, term()}

  @doc "Restore a quiescent state snapshot into this implementation."
  @callback restore(snapshot()) :: {:ok, EngineState.t()} | {:error, term()}

  @optional_callbacks snapshot: 1, restore: 1

  @doc "Return the stable Runtime Graph contract reference."
  @spec ref() :: ContractRef.t()
  def ref, do: ContractRef.new!("catalyst.session-engine", 1)
end
