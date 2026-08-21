defmodule Catalyst.Runtime.Claim do
  @moduledoc """
  One owner's implementation claim for a logical runtime service.

  Claims are immutable data consumed by `Catalyst.Runtime.Resolver`. Physical
  storage and lifecycle ownership remain subsystem-specific during phase one.
  """

  alias Catalyst.Runtime.{ContractRef, Scope, ServiceKey}

  @enforce_keys [
    :key,
    :contract,
    :implementation,
    :owner,
    :scope,
    :priority,
    :binding,
    :provenance
  ]
  defstruct @enforce_keys ++ [health: :ready, metadata: %{}]

  @type health :: :ready | :starting | :unhealthy | :draining
  @type binding :: :live | {:pin, atom()}

  @type t :: %__MODULE__{
          key: ServiceKey.t(),
          contract: ContractRef.t(),
          implementation: term(),
          owner: term(),
          scope: Scope.t(),
          priority: integer(),
          binding: binding(),
          provenance: term(),
          health: health(),
          metadata: map()
        }

  @doc "Stable ordering key used for deterministic snapshots and explanations."
  @spec stable_key(t()) :: term()
  def stable_key(%__MODULE__{} = claim) do
    {
      ServiceKey.to_wire(claim.key),
      {claim.contract.id, claim.contract.version},
      Scope.specificity(claim.scope),
      claim.scope.constraints,
      claim.priority,
      inspect(claim.owner),
      inspect(claim.provenance),
      inspect(claim.implementation),
      inspect(claim.binding),
      inspect(claim.health),
      inspect(claim.metadata)
    }
  end
end
