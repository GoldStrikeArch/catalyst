defmodule Catalyst.Runtime.ActivationId do
  @moduledoc """
  Unique identity of one staged or published runtime activation.

  Unlike `Catalyst.Runtime.GenerationId`, an activation identity is intentionally
  not derived from graph contents. Activating the same graph twice creates two
  different process, lease, and artifact lifecycles.
  """

  @enforce_keys [:value]
  defstruct @enforce_keys

  @type t :: %__MODULE__{value: pos_integer()}

  @doc "Create a VM-local, monotonically unique activation identity."
  @spec new() :: t()
  def new do
    %__MODULE__{value: System.unique_integer([:monotonic, :positive])}
  end

  @doc "Return the wire-safe representation of an activation identity."
  @spec to_wire(t()) :: String.t()
  def to_wire(%__MODULE__{value: value}), do: "activation:#{value}"
end
