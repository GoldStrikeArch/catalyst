defmodule Catalyst.Runtime.Lease do
  @moduledoc """
  Process-owned lease retaining one managed runtime generation.

  A lease pins generation lifecycle, not exact BEAM code. Generation-qualified
  physical modules remain a later runtime milestone.
  """

  alias Catalyst.Runtime.GenerationId

  @enforce_keys [:ref, :generation, :owner, :binding, :acquired_at]
  defstruct @enforce_keys

  @type binding :: atom()

  @type t :: %__MODULE__{
          ref: reference(),
          generation: GenerationId.t(),
          owner: pid(),
          binding: binding(),
          acquired_at: DateTime.t()
        }
end
