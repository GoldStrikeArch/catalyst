defmodule Catalyst.Runtime.Handle do
  @moduledoc """
  Pinned runtime service selection with an optional managed-generation lease.

  Built-in and imperative claims do not belong to a managed generation and
  therefore produce handles whose `lease` and `generation` fields are `nil`.
  """

  alias Catalyst.Runtime.{Lease, Leases, Resolution}

  @enforce_keys [:resolution, :implementation, :owner, :binding]
  defstruct @enforce_keys ++ [generation: nil, lease: nil]

  @type t :: %__MODULE__{
          resolution: Resolution.t(),
          implementation: module() | term(),
          owner: term(),
          binding: Catalyst.Runtime.Claim.binding(),
          generation: Catalyst.Runtime.GenerationId.t() | nil,
          lease: Lease.t() | nil
        }

  @doc "Build a handle from a logical resolution and its acquired lease."
  @spec new(Resolution.t(), Lease.t() | nil) :: t()
  def new(%Resolution{} = resolution, lease) do
    %__MODULE__{
      resolution: resolution,
      implementation: resolution.claim.implementation,
      owner: resolution.claim.owner,
      binding: resolution.binding,
      generation: generation(lease),
      lease: lease
    }
  end

  @doc "Release the handle's managed-generation lease, if present."
  @spec release(t()) :: :ok
  def release(%__MODULE__{lease: nil}), do: :ok
  def release(%__MODULE__{lease: lease}), do: Leases.release(lease)

  defp generation(nil), do: nil
  defp generation(%Lease{generation: generation}), do: generation
end
