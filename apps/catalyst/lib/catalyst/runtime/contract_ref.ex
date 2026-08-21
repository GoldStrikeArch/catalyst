defmodule Catalyst.Runtime.ContractRef do
  @moduledoc """
  Reference to one version of a public runtime service contract.

  Phase one uses exact major-version compatibility. Future negotiation may add
  ranges without changing claim or resolution shapes.
  """

  @enforce_keys [:id, :version]
  defstruct @enforce_keys

  @type t :: %__MODULE__{id: String.t(), version: pos_integer()}

  @doc "Build a validated contract reference."
  @spec new(String.t(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def new(id, version)

  def new(id, version)
      when is_binary(id) and byte_size(id) > 0 and is_integer(version) and version > 0 do
    case String.trim(id) do
      ^id -> {:ok, %__MODULE__{id: id, version: version}}
      _trimmed -> {:error, {:invalid_contract_ref, id, version}}
    end
  end

  def new(id, version), do: {:error, {:invalid_contract_ref, id, version}}

  @doc "Build a contract reference, raising `ArgumentError` when invalid."
  @spec new!(String.t(), pos_integer()) :: t()
  def new!(id, version) do
    case new(id, version) do
      {:ok, contract} -> contract
      {:error, reason} -> raise ArgumentError, "invalid contract reference: #{inspect(reason)}"
    end
  end

  @doc "Whether a claim contract exactly satisfies the requested phase-one contract."
  @spec compatible?(t(), t()) :: boolean()
  def compatible?(%__MODULE__{} = claim, %__MODULE__{} = requested),
    do: claim.id == requested.id and claim.version == requested.version
end
