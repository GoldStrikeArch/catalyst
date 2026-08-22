defmodule Catalyst.Runtime.Lease do
  @moduledoc """
  Process-owned lease retaining one managed runtime generation.

  A lease pins one unique activation lifecycle. Exact BEAM retention additionally
  requires the activation's artifact set to remain loaded until this lease drains.
  """

  alias Catalyst.Runtime.ActivationId

  @enforce_keys [:ref, :generation, :owner, :binding, :acquired_at]
  defstruct @enforce_keys

  @type binding :: atom()

  @type t :: %__MODULE__{
          ref: reference(),
          generation: ActivationId.t(),
          owner: pid(),
          binding: binding(),
          acquired_at: DateTime.t()
        }
end
