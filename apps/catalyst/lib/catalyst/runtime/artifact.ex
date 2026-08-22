defmodule Catalyst.Runtime.Artifact do
  @moduledoc """
  Lifecycle record for one generation-qualified compiled artifact.

  Pending artifacts have been compiled and registered but are not yet attached
  to a candidate activation. Retained artifacts remain loaded while one or more
  active or retiring activations reference them. Purge failures remain visible
  and retryable rather than being silently forgotten.
  """

  alias Catalyst.Runtime.{ActivationId, ArtifactId, ArtifactSet}

  @enforce_keys [:id, :set, :status, :activations, :inserted_at]
  defstruct @enforce_keys ++ [purged_at: nil, reason: nil]

  @type status :: :pending | :retained | :purge_failed

  @type t :: %__MODULE__{
          id: ArtifactId.t(),
          set: ArtifactSet.t(),
          status: status(),
          activations: MapSet.t(ActivationId.t()),
          inserted_at: DateTime.t(),
          purged_at: DateTime.t() | nil,
          reason: term()
        }
end
