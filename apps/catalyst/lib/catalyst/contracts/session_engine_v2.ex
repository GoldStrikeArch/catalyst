defmodule Catalyst.Contracts.SessionEngine.V2 do
  @moduledoc """
  Version-two contract for a pure, session-bound semantic state machine.

  The stable session host owns OTP messaging, run tasks, persistence ordering,
  PubSub, runtime handles, and effect interpretation. An implementation owns
  semantic commands, event reduction, private engine state, and bounded state
  handoff.
  """

  alias Catalyst.Message
  alias Catalyst.Runtime.ContractRef
  alias Catalyst.Session.{Effect, EngineState, EventEnvelope, StateCapsule}

  @typedoc "Implementation-private state retained beside the host's semantic projection."
  @type engine_state :: term()

  @typedoc "A command accepted by the version-two semantic state machine."
  @type command ::
          {:prompt, Message.User.t(), :idle | :busy}
          | {:submit, Message.User.t(), :idle | :busy}
          | {:enqueue, :steering | :follow_up, Message.User.t()}
          | {:drain, :steering | :follow_up}
          | :reset

  @doc "Initialize implementation-private state for one newly opened session."
  @callback init(map()) :: {:ok, engine_state()} | {:error, term()}

  @doc "Apply one semantic command without performing host side effects."
  @callback command(command(), EngineState.t(), engine_state()) ::
              {:ok, EngineState.t(), engine_state(), [Effect.t()], term()} | {:error, term()}

  @doc "Fold one accepted event without performing host side effects."
  @callback event(EventEnvelope.t(), EngineState.t(), engine_state()) ::
              {:ok, EngineState.t(), engine_state(), [Effect.t()]} | {:error, term()}

  @doc "Build repair results for tool calls orphaned by an interrupted run."
  @callback aborted_tool_results(EngineState.t(), engine_state(), term()) ::
              [Message.ToolResult.t()]

  @doc "Build the terminal assistant message for a failed or aborted run."
  @callback failure_message(EngineState.t(), engine_state(), term()) :: Message.Assistant.t()

  @doc "Return the implementation's state schema version."
  @callback state_version() :: pos_integer()

  @doc "Produce the bounded, process-independent payload for a handoff capsule."
  @callback snapshot(EngineState.t(), engine_state()) :: {:ok, term()} | {:error, term()}

  @doc "Restore semantic and private state from a verified capsule."
  @callback restore(StateCapsule.t()) ::
              {:ok, EngineState.t(), engine_state()} | {:error, term()}

  @doc "Verify the restored state before the host swaps generation handles."
  @callback verify_handoff(StateCapsule.t(), EngineState.t(), engine_state()) ::
              :ok | {:error, term()}

  @doc "Return the stable Runtime Graph contract reference."
  @spec ref() :: ContractRef.t()
  def ref, do: ContractRef.new!("catalyst.session-engine", 2)
end
