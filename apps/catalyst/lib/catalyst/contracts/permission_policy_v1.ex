defmodule Catalyst.Contracts.PermissionPolicy.V1 do
  @moduledoc """
  Version-one authorization contract for brokered Catalyst actions.

  A policy decision controls only callers that use this contract. Trusted
  in-process extensions can still call operating-system and BEAM APIs directly.
  """

  alias Catalyst.Runtime.ContractRef

  @type decision :: :allow | {:deny, term()} | {:challenge, map()}

  @doc "Authorize one action for a principal and resource."
  @callback authorize(action :: map(), principal :: map(), resource :: map(), context :: map()) ::
              decision()

  @doc "Return the stable Runtime Graph contract reference."
  @spec ref() :: ContractRef.t()
  def ref, do: ContractRef.new!("catalyst.permission-policy", 1)
end
