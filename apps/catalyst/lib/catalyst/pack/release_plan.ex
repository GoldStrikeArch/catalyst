defmodule Catalyst.Pack.ReleasePlan do
  @moduledoc """
  Deterministic release inputs aggregated from compiled pack manifests.

  Aggregation only copies validated data. Build tooling may interpret the
  returned declarations later, at its explicit execution boundary.
  """

  alias Catalyst.Pack.{Manifest, Registry}

  @enforce_keys [:packs, :assets, :sidecars, :contributions]
  defstruct @enforce_keys

  @type owned_declaration :: %{pack_id: String.t(), declaration: map()}
  @type t :: %__MODULE__{
          packs: [String.t()],
          assets: [owned_declaration()],
          sidecars: [owned_declaration()],
          contributions: [owned_declaration()]
        }

  @doc "Resolve pack IDs and aggregate their declarative release inputs."
  @spec for_packs([String.t()]) :: {:ok, t()} | {:error, term()}
  def for_packs(ids) do
    with {:ok, manifests} <- Registry.resolve(ids) do
      {:ok, aggregate(manifests)}
    end
  end

  @doc "Aggregate already validated manifests without executing callbacks."
  @spec aggregate([Manifest.t()]) :: t()
  def aggregate(manifests) when is_list(manifests) do
    %__MODULE__{
      packs: Enum.map(manifests, & &1.id),
      assets: owned(manifests, :assets),
      sidecars: owned(manifests, :sidecars),
      contributions: owned(manifests, :release_contributions)
    }
  end

  defp owned(manifests, field) do
    for manifest <- manifests,
        declaration <- Map.fetch!(manifest, field),
        do: %{pack_id: manifest.id, declaration: declaration}
  end
end
