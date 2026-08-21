defmodule Catalyst.Runtime.Contribution do
  @moduledoc """
  One owner-scoped contribution to a cardinality-many runtime extension point.

  Contributions describe additive capabilities such as tools, hooks, prompt
  overlays, UI pages, and commands. Replaceable singleton services use
  `Catalyst.Runtime.Claim` instead.
  """

  alias Catalyst.Runtime.Scope

  @enforce_keys [:point, :id, :value, :owner, :scope, :provenance]
  defstruct @enforce_keys ++ [metadata: %{}]

  @type t :: %__MODULE__{
          point: String.t(),
          id: term(),
          value: term(),
          owner: term(),
          scope: Scope.t(),
          provenance: term(),
          metadata: map()
        }

  @doc "Stable ordering key used for deterministic graph snapshots."
  @spec stable_key(t()) :: term()
  def stable_key(%__MODULE__{} = contribution) do
    {
      contribution.point,
      inspect(contribution.id),
      inspect(contribution.value),
      inspect(contribution.owner),
      inspect(contribution.scope.constraints),
      inspect(contribution.provenance),
      inspect(contribution.metadata)
    }
  end
end
