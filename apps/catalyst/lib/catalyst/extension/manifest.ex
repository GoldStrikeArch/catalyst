defmodule Catalyst.Extension.Manifest do
  @moduledoc """
  Declarative API-v2 description of one extension's proposed runtime footprint.

  A manifest is inert data. Constructing or discovering one does not register
  services, mutate extension points, start processes, or run health checks.
  `Catalyst.Runtime.Candidate.Builder` combines validated manifests into a
  deterministic candidate plan for later staging and activation work.
  """

  alias Catalyst.Extension.Manifest.Validator

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
  def digest_term(%__MODULE__{} = manifest), do: Map.from_struct(manifest)
end
