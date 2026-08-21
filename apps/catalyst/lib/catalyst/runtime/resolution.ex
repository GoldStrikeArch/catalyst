defmodule Catalyst.Runtime.Resolution do
  @moduledoc """
  Selected runtime claim and its explanation.

  This value pins logical selection data for a binding boundary. Callers that
  execute managed services acquire a `Catalyst.Runtime.Handle`; explanation and
  preview callers may inspect a resolution without retaining its generation.
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
