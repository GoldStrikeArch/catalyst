defmodule Catalyst.Runtime.Generation do
  @moduledoc """
  Lifecycle record for one active, retiring, retired, rejected, or failed candidate.

  Generation records are diagnostic data. The immutable active candidate in
  `Catalyst.Runtime.GenerationStore` is the authority used by runtime readers.
  """

  alias Catalyst.Runtime.{ActivationId, Candidate, GenerationId}

  @enforce_keys [:id, :graph_id, :candidate, :owners, :status, :inserted_at]
  defstruct @enforce_keys ++
              [
                parent: nil,
                activated_at: nil,
                retiring_at: nil,
                drain_deadline: nil,
                drain_timed_out_at: nil,
                forced_retirement_at: nil,
                retired_at: nil,
                rejected_at: nil,
                lease_count: 0,
                reason: nil
              ]

  @type status :: :active | :retiring | :retired | :rejected | :failed

  @type t :: %__MODULE__{
          id: ActivationId.t(),
          graph_id: GenerationId.t(),
          candidate: Candidate.t(),
          owners: %{optional(String.t()) => [Catalyst.Extension.Manifest.t()]},
          status: status(),
          inserted_at: DateTime.t(),
          parent: ActivationId.t() | nil,
          activated_at: DateTime.t() | nil,
          retiring_at: DateTime.t() | nil,
          drain_deadline: DateTime.t() | nil,
          drain_timed_out_at: DateTime.t() | nil,
          forced_retirement_at: DateTime.t() | nil,
          retired_at: DateTime.t() | nil,
          rejected_at: DateTime.t() | nil,
          lease_count: non_neg_integer() | :unknown,
          reason: term()
        }
end
