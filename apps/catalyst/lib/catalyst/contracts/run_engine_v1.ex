defmodule Catalyst.Contracts.RunEngine.V1 do
  @moduledoc """
  Version-one contract for an implementation that owns one complete agent run.

  Existing `Catalyst.Workflow` implementations satisfy this execution shape.
  The contract reference lets the Runtime Graph describe that compatibility
  without requiring built-in and extension modules to adopt a second behaviour.
  """

  alias Catalyst.Runtime.ContractRef

  @doc "Return the stable Runtime Graph contract reference."
  @spec ref() :: ContractRef.t()
  def ref, do: ContractRef.new!("catalyst.agent-run-engine", 1)
end
