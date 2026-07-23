defmodule Catalyst.Context.Compaction do
  @moduledoc """
  A context policy's proposed chronological transcript replacement.

  The replacement is advisory until `Catalyst.Context.Guard` validates the
  message shape and recomputes the authoritative accounting (replaced count,
  token totals, and policy provenance) for the staged request.  The candidate
  therefore carries only what the guard cannot derive itself: the replacement
  list and the optional summary message it must contain.
  """

  @enforce_keys [:replacement]
  defstruct [:replacement, :summary]

  @type t :: %__MODULE__{
          replacement: [Catalyst.Message.t()],
          summary: Catalyst.Message.User.t() | nil
        }
end
