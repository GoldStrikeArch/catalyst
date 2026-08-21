defmodule Catalyst.Runtime.Generation do
  @moduledoc """
  Lifecycle record for one planned, active, rejected, or retired candidate.

  Generation records are diagnostic data. The immutable active candidate in
  `Catalyst.Runtime.GenerationStore` is the authority used by runtime readers.
  """

  alias Catalyst.Runtime.{Candidate, GenerationId}

  @enforce_keys [:id, :candidate, :owners, :status, :inserted_at]
  defstruct @enforce_keys ++
              [
                parent: nil,
                activated_at: nil,
                retired_at: nil,
                rejected_at: nil,
                reason: nil
              ]

  @type status :: :active | :retired | :rejected | :failed

  @type t :: %__MODULE__{
          id: GenerationId.t(),
          candidate: Candidate.t(),
          owners: %{optional(String.t()) => [Catalyst.Extension.Manifest.t()]},
          status: status(),
          inserted_at: DateTime.t(),
          parent: GenerationId.t() | nil,
          activated_at: DateTime.t() | nil,
          retired_at: DateTime.t() | nil,
          rejected_at: DateTime.t() | nil,
          reason: term()
        }
end
