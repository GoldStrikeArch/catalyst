defmodule Catalyst.Runtime.Explanation do
  @moduledoc "Complete trace of one runtime service-resolution decision."

  alias Catalyst.Runtime.{Claim, Context, ContractRef, ServiceKey}

  @enforce_keys [
    :key,
    :contract,
    :context,
    :selected,
    :hidden,
    :rejected,
    :status,
    :snapshot_id
  ]
  defstruct @enforce_keys

  @type rejection :: %{claim: Claim.t(), reason: term()}

  @type t :: %__MODULE__{
          key: ServiceKey.t(),
          contract: ContractRef.t() | nil,
          context: Context.t(),
          selected: Claim.t() | nil,
          hidden: [Claim.t()],
          rejected: [rejection()],
          status: :resolved | {:error, term()},
          snapshot_id: String.t()
        }
end
