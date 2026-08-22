defmodule Catalyst.Runtime.ArtifactId do
  @moduledoc """
  Identity of one compiled code artifact.

  Artifact identities are separate from graph and activation identities because
  identical declarations may still have different executable code.
  """

  @enforce_keys [:value]
  defstruct @enforce_keys

  @type t :: %__MODULE__{value: String.t()}

  @doc "Create a unique artifact identity suitable for a physical module namespace."
  @spec new() :: t()
  def new do
    value =
      12
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    %__MODULE__{value: value}
  end

  @doc """
  Derive a stable artifact identity from source and the local compiler runtime.

  Recompiling byte-identical source on the same Elixir/OTP runtime reuses the
  physical module namespace instead of minting permanent module-name atoms.
  """
  @spec from_source(binary()) :: t()
  def from_source(source) when is_binary(source) do
    value =
      :sha256
      |> :crypto.hash([
        source,
        <<0>>,
        System.version(),
        <<0>>,
        System.otp_release()
      ])
      |> Base.encode16(case: :lower)

    %__MODULE__{value: value}
  end

  @doc "Return the wire-safe representation of an artifact identity."
  @spec to_wire(t()) :: String.t()
  def to_wire(%__MODULE__{value: value}), do: "artifact:#{value}"

  @doc false
  @spec module_segment(t()) :: atom()
  def module_segment(%__MODULE__{value: value}), do: String.to_atom("A" <> value)
end
