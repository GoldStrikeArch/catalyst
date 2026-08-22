defmodule Catalyst.Pack.Manifest do
  @moduledoc """
  Validated, declarative metadata for one compiled capability pack.

  Manifests describe composition only. They do not contain or invoke runtime
  callbacks, so catalog and release-plan resolution remain deterministic.
  """

  alias Catalyst.Pack.ReleaseContribution

  @enforce_keys [:id, :version, :trust]
  defstruct id: nil,
            version: nil,
            contracts: [],
            services: [],
            extension_points: [],
            contributions: [],
            processes: [],
            assets: [],
            sidecars: [],
            release_contributions: [],
            dependencies: [],
            hosts: [:cli, :web, :desktop],
            platforms: [:any],
            trust: nil

  @hosts [:cli, :web, :desktop]
  @platforms [:any, :darwin, :linux, :windows]
  @trust_classes [:compiled_trusted, :local_trusted, :isolated_worker, :remote_service]
  @max_manifest_bytes 1_048_576
  @declaration_fields [
    :contracts,
    :services,
    :extension_points,
    :contributions,
    :processes,
    :assets,
    :sidecars,
    :release_contributions
  ]

  @type host :: :cli | :web | :desktop
  @type platform :: :any | :darwin | :linux | :windows
  @type trust_class ::
          :compiled_trusted | :local_trusted | :isolated_worker | :remote_service
  @type dependency :: %{id: String.t(), requirement: String.t()}
  @type declaration :: map()
  @type t :: %__MODULE__{
          id: String.t(),
          version: String.t(),
          contracts: [declaration()],
          services: [declaration()],
          extension_points: [declaration()],
          contributions: [declaration()],
          processes: [declaration()],
          assets: [declaration()],
          sidecars: [declaration()],
          release_contributions: [declaration()],
          dependencies: [dependency()],
          hosts: [host()],
          platforms: [platform()],
          trust: trust_class()
        }

  @doc "Build and validate a pack manifest."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()
  def new(%__MODULE__{} = manifest), do: validate(manifest)

  def new(attrs) when is_map(attrs) do
    attrs
    |> then(&struct(__MODULE__, &1))
    |> validate()
  rescue
    error in [ArgumentError, KeyError] -> {:error, {:invalid_pack_manifest, error}}
  end

  def new(attrs), do: {:error, {:invalid_pack_manifest, attrs}}

  @doc "Build a pack manifest, raising when compiled catalog data is invalid."
  @spec new!(map() | keyword() | t()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, manifest} -> manifest
      {:error, reason} -> raise ArgumentError, "invalid pack manifest: #{inspect(reason)}"
    end
  end

  @doc "Return whether a value is a valid stable pack identifier."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(value) when is_binary(value) do
    value != "" and byte_size(value) <= 128 and
      String.match?(value, ~r/\A[a-z0-9][a-z0-9._-]*\z/)
  end

  def valid_id?(_value), do: false

  defp validate(manifest) do
    with :ok <- validate_id(manifest.id),
         :ok <- validate_version(manifest.version),
         :ok <- validate_declarations(manifest),
         {:ok, release_contributions} <-
           ReleaseContribution.validate_all(manifest.release_contributions),
         {:ok, dependencies} <- normalize_dependencies(manifest.dependencies),
         :ok <- validate_enum_list(:hosts, manifest.hosts, @hosts),
         :ok <- validate_enum_list(:platforms, manifest.platforms, @platforms),
         :ok <- validate_trust(manifest.trust),
         manifest = %{
           manifest
           | dependencies: dependencies,
             release_contributions: release_contributions
         },
         :ok <- validate_size(manifest) do
      {:ok, manifest}
    end
  end

  defp validate_id(id) do
    case valid_id?(id) do
      true -> :ok
      false -> {:error, {:invalid_pack_id, id}}
    end
  end

  defp validate_version(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, _version} -> :ok
      :error -> {:error, {:invalid_pack_version, version}}
    end
  end

  defp validate_version(version), do: {:error, {:invalid_pack_version, version}}

  defp validate_declarations(manifest) do
    Enum.reduce_while(@declaration_fields, :ok, fn field, :ok ->
      values = Map.fetch!(manifest, field)

      case valid_declarations?(values) do
        true -> {:cont, :ok}
        false -> {:halt, {:error, {:invalid_pack_field, field, values}}}
      end
    end)
  end

  defp valid_declarations?(values) when is_list(values) do
    Enum.all?(values, &(is_map(&1) and declarative?(&1)))
  end

  defp valid_declarations?(_values), do: false

  defp normalize_dependencies(dependencies) when is_list(dependencies) do
    dependencies
    |> Enum.reduce_while({:ok, []}, fn dependency, {:ok, acc} ->
      case normalize_dependency(dependency) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> normalize_dependency_result(dependencies)
  end

  defp normalize_dependencies(dependencies),
    do: {:error, {:invalid_pack_field, :dependencies, dependencies}}

  defp normalize_dependency(id) when is_binary(id),
    do: normalize_dependency(%{id: id, requirement: ">= 0.0.0"})

  defp normalize_dependency(%{id: id, requirement: requirement})
       when is_binary(requirement) do
    with true <- valid_id?(id),
         {:ok, _parsed} <- Version.parse_requirement(requirement) do
      {:ok, %{id: id, requirement: requirement}}
    else
      _invalid -> {:error, {:invalid_pack_dependency, id, requirement}}
    end
  end

  defp normalize_dependency(dependency), do: {:error, {:invalid_pack_dependency, dependency}}

  defp normalize_dependency_result({:ok, dependencies}, original) do
    dependencies = Enum.reverse(dependencies)

    case unique?(Enum.map(dependencies, & &1.id)) do
      true -> {:ok, dependencies}
      false -> {:error, {:invalid_pack_field, :dependencies, original}}
    end
  end

  defp normalize_dependency_result({:error, _reason} = error, _original), do: error

  defp validate_enum_list(field, values, allowed) when is_list(values) and values != [] do
    case Enum.all?(values, &(&1 in allowed)) and unique?(values) do
      true -> :ok
      false -> {:error, {:invalid_pack_field, field, values}}
    end
  end

  defp validate_enum_list(field, values, _allowed),
    do: {:error, {:invalid_pack_field, field, values}}

  defp validate_trust(trust) do
    case trust in @trust_classes do
      true -> :ok
      false -> {:error, {:invalid_pack_trust, trust}}
    end
  end

  defp validate_size(manifest) do
    case :erlang.external_size(manifest) <= @max_manifest_bytes do
      true -> :ok
      false -> {:error, {:pack_manifest_too_large, manifest.id}}
    end
  end

  defp unique?(values), do: length(values) == MapSet.size(MapSet.new(values))

  defp declarative?(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) or
              is_atom(value),
       do: true

  defp declarative?(value) when is_list(value), do: Enum.all?(value, &declarative?/1)

  defp declarative?(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.all?(&declarative?/1)
  end

  defp declarative?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> declarative?(key) and declarative?(nested) end)
  end

  defp declarative?(_value), do: false
end
