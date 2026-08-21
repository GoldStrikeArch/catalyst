defmodule Catalyst.Runtime.GenerationId do
  @moduledoc """
  Stable identity of a planned or activated runtime generation.

  Candidate identities are deterministic digests of their normalized graph and
  parent generation. Durable last-known-good pointers remain Recovery Host work.
  """

  @enforce_keys [:kind, :value]
  defstruct @enforce_keys

  @type kind :: :candidate | :active
  @type t :: %__MODULE__{kind: kind(), value: String.t() | non_neg_integer()}

  @doc "Build the deterministic identity for a candidate digest."
  @spec candidate(String.t()) :: t()
  def candidate(digest) when is_binary(digest) and byte_size(digest) == 64,
    do: %__MODULE__{kind: :candidate, value: digest}

  @doc "Return the wire-safe representation of a generation identity."
  @spec to_wire(t()) :: String.t()
  def to_wire(%__MODULE__{kind: kind, value: value}), do: "#{kind}:#{value}"
end
