defmodule Catalyst.Contracts.SessionFactory.V1 do
  @moduledoc """
  Version-one contract for managed local session construction.

  Factories return an OTP child spec that starts a local, Registry-compatible
  session process. Locate, command transport, and remote or sovereign session
  runtimes are deliberately outside this contract.
  """

  alias Catalyst.Runtime.ContractRef

  @doc "Build a local session child spec, preserving the supplied host options."
  @callback child_spec(keyword()) :: {:ok, Supervisor.child_spec()} | {:error, term()}

  @doc "Return the stable Runtime Graph contract reference."
  @spec ref() :: ContractRef.t()
  def ref, do: ContractRef.new!("catalyst.session-factory", 1)
end
