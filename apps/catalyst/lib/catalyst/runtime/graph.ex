defmodule Catalyst.Runtime.Graph do
  @moduledoc """
  Immutable aggregate read model of the currently observable runtime graph.

  `source_status` distinguishes healthy adapters from unavailable or malformed
  sources, so registry recovery cannot be misreported as an intentionally empty
  composition.
  """

  alias Catalyst.Runtime.{Claim, Context, Contribution}

  @enforce_keys [
    :snapshot_id,
    :context,
    :claims,
    :contributions,
    :source_status,
    :source_metadata,
    :generated_at
  ]
  defstruct @enforce_keys

  @type source_status :: %{required(atom()) => :ready | {:error, term()}}

  @type t :: %__MODULE__{
          snapshot_id: String.t(),
          context: Context.t(),
          claims: [Claim.t()],
          contributions: [Contribution.t()],
          source_status: source_status(),
          source_metadata: %{optional(atom()) => map()},
          generated_at: DateTime.t()
        }
end
