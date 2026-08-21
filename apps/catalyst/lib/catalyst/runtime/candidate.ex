defmodule Catalyst.Runtime.Candidate do
  @moduledoc """
  Immutable, non-activating plan for a proposed runtime generation.

  A candidate contains normalized claims, extension points, contributions,
  process declarations, health checks, migrations, capabilities, and provenance.
  It does not load code, start processes, mutate registries, or publish an active
  generation pointer.
  """

  alias Catalyst.Extension.Manifest
  alias Catalyst.Runtime.{Claim, Contribution, ExtensionPoint, GenerationId}

  @enforce_keys [
    :id,
    :parent,
    :manifests,
    :claims,
    :extension_points,
    :contributions,
    :processes,
    :health_checks,
    :migrations,
    :capabilities,
    :digest
  ]

  defstruct @enforce_keys ++ [status: :planned]

  @type t :: %__MODULE__{
          id: GenerationId.t(),
          parent: GenerationId.t() | nil,
          manifests: [Manifest.t()],
          claims: [Claim.t()],
          extension_points: [ExtensionPoint.t()],
          contributions: [Contribution.t()],
          processes: [map()],
          health_checks: [map()],
          migrations: [map()],
          capabilities: [map()],
          digest: String.t(),
          status: :planned
        }
end
