defmodule Catalyst.Runtime.Candidate do
  @moduledoc """
  Immutable, non-activating plan for a proposed runtime generation.

  A candidate contains normalized claims, extension points, contributions,
  process declarations, health checks, migrations, capabilities, and provenance.
  It does not load code, start processes, mutate registries, or publish an active
  generation pointer.
  """

  alias Catalyst.Extension.Manifest

  alias Catalyst.Runtime.{
    ActivationId,
    ArtifactId,
    Claim,
    Contribution,
    ExtensionPoint,
    GenerationId
  }

  @enforce_keys [
    :id,
    :parent,
    :manifests,
    :artifacts,
    :claims,
    :extension_points,
    :contributions,
    :processes,
    :health_checks,
    :migrations,
    :capabilities,
    :digest
  ]

  defstruct @enforce_keys ++ [activation_id: nil, status: :planned]

  @type t :: %__MODULE__{
          id: GenerationId.t(),
          parent: ActivationId.t() | nil,
          activation_id: ActivationId.t() | nil,
          manifests: [Manifest.t()],
          artifacts: [ArtifactId.t()],
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
