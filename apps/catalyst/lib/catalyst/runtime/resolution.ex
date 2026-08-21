defmodule Catalyst.Runtime.Resolution do
  @moduledoc """
  Selected runtime claim and its explanation.

  This phase-one value is not a lease. It pins logical selection data for a
  binding boundary, but does not yet delay extension module purge.
  """

  alias Catalyst.Runtime.{Claim, ContractRef, Explanation, ServiceKey}

  @enforce_keys [:key, :contract, :claim, :binding, :snapshot_id, :explanation]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          key: ServiceKey.t(),
          contract: ContractRef.t(),
          claim: Claim.t(),
          binding: Claim.binding(),
          snapshot_id: String.t(),
          explanation: Explanation.t()
        }
end
