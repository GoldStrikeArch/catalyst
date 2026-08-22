defmodule Catalyst.Extension.Manifest do
  @moduledoc """
  Declarative API-v2 description of one extension's proposed runtime footprint.

  A manifest is inert data. Constructing or discovering one does not register
  services, mutate extension points, start processes, or run health checks.
  `Catalyst.Runtime.Candidate.Builder` combines validated manifests into a
  deterministic candidate plan for later staging and activation work.
  """

  alias Catalyst.Extension.Manifest.Validator
  alias Catalyst.Runtime.ImplementationRef

  @enforce_keys [:api, :id, :version]
  defstruct api: 2,
            id: nil,
            version: nil,
            requires: [],
            services: [],
            extension_points: [],
            contributions: [],
            processes: [],
            health_checks: [],
            migrations: [],
            capabilities: [],
            metadata: %{}

  @type dependency :: %{id: String.t(), requirement: String.t()}

  @type t :: %__MODULE__{
          api: 2,
          id: String.t(),
          version: String.t(),
          requires: [dependency()],
          services: [map()],
          extension_points: [map()],
          contributions: [map()],
          processes: [map()],
          health_checks: [map()],
          migrations: [map()],
          capabilities: [atom()],
          metadata: map()
        }

  @doc """
  Validate and normalize a manifest map.

  Expected failures are returned as tagged tuples. No runtime registration or
  extension callback is performed.
  """
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(manifest), do: Validator.validate(manifest)

  @doc "Build a manifest, raising `ArgumentError` when invalid."
  @spec new!(t() | map() | keyword()) :: t()
  def new!(manifest) do
    case new(manifest) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "invalid extension manifest: #{inspect(reason)}"
    end
  end

  @doc "Stable data used when digesting a candidate generation."
  @spec digest_term(t()) :: map()
  def digest_term(%__MODULE__{} = manifest) do
    manifest
    |> Map.from_struct()
    |> logical_term()
  end

  defp logical_term(%ImplementationRef{} = reference),
    do: ImplementationRef.digest_term(reference)

  defp logical_term(%_struct{} = value) do
    value
    |> Map.from_struct()
    |> logical_term()
  end

  defp logical_term(value) when is_list(value), do: Enum.map(value, &logical_term/1)

  defp logical_term(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&logical_term/1)
    |> List.to_tuple()
  end

  defp logical_term(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {logical_term(key), logical_term(item)} end)
  end

  defp logical_term(value), do: value
end
