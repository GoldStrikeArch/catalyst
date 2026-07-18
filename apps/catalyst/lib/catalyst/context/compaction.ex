defmodule Catalyst.Context.Compaction do
  @moduledoc """
  A context policy's proposed chronological transcript replacement.

  The replacement is advisory until `Catalyst.Context.Guard` validates the
  message shape and recomputes the exact staged request estimate.  Policies
  therefore cannot make persistence diverge from the request that was checked.
  """

  @enforce_keys [:replacement, :replaced_count, :tokens_before, :tokens_after, :policy]
  defstruct [:replacement, :summary, :replaced_count, :tokens_before, :tokens_after, :policy]

  @type t :: %__MODULE__{
          replacement: [Catalyst.Message.t()],
          summary: Catalyst.Message.User.t() | nil,
          replaced_count: non_neg_integer(),
          tokens_before: non_neg_integer(),
          tokens_after: non_neg_integer(),
          policy: term()
        }
end
