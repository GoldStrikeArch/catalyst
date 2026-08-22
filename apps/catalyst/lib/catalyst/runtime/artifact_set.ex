defmodule Catalyst.Runtime.ArtifactSet do
  @moduledoc """
  Compiled physical modules belonging to one immutable code artifact.

  The artifact lifecycle manager retains the whole set while any activation
  references it and purges every physical module after the final reference is
  released.
  """

  alias Catalyst.Runtime.ArtifactId

  @enforce_keys [:id, :modules, :beams]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: ArtifactId.t(),
          modules: %{optional(module()) => module()},
          beams: %{optional(module()) => binary()}
        }

  @doc "Build an artifact set from logical-to-physical modules and accepted BEAM binaries."
  @spec new(ArtifactId.t(), %{module() => module()}, %{module() => binary()}) :: t()
  def new(%ArtifactId{} = id, modules, beams) when is_map(modules) and is_map(beams) do
    %__MODULE__{id: id, modules: modules, beams: beams}
  end

  @doc "Return the physical module for a logical module."
  @spec target(t(), module()) :: {:ok, module()} | :error
  def target(%__MODULE__{modules: modules}, logical), do: Map.fetch(modules, logical)

  @doc "Return the logical module for a physical module."
  @spec logical(t(), module()) :: {:ok, module()} | :error
  def logical(%__MODULE__{modules: modules}, physical) do
    modules
    |> Enum.find_value(:error, fn
      {logical, ^physical} -> {:ok, logical}
      _entry -> false
    end)
  end

  @doc "List physical modules in stable logical-module order."
  @spec physical_modules(t()) :: [module()]
  def physical_modules(%__MODULE__{modules: modules}) do
    modules
    |> Enum.sort_by(fn {logical, _physical} -> inspect(logical) end)
    |> Enum.map(&elem(&1, 1))
  end

  @doc "True when a loaded module belongs to the runtime-artifact namespace."
  @spec physical_module?(module()) :: boolean()
  def physical_module?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Catalyst.RuntimeArtifact.")
  end
end
