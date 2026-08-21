defmodule Catalyst.Extension.Manifest.Validator do
  @moduledoc """
  Pure structural validation for `Catalyst.Extension.Manifest`.

  Cross-manifest dependencies, extension-point compatibility, collisions, and
  candidate graph construction belong to `Catalyst.Runtime.Candidate.Builder`.
  """

  alias Catalyst.Extension.Manifest

  @fields [
    :api,
    :id,
    :version,
    :requires,
    :services,
    :extension_points,
    :contributions,
    :processes,
    :health_checks,
    :migrations,
    :capabilities,
    :metadata
  ]

  @declaration_fields [
    :services,
    :extension_points,
    :contributions,
    :processes,
    :health_checks,
    :migrations
  ]

  @doc "Validate and normalize one API-v2 manifest."
  @spec validate(Manifest.t() | map() | keyword()) :: {:ok, Manifest.t()} | {:error, term()}
  def validate(%Manifest{} = manifest), do: validate(Map.from_struct(manifest))

  def validate(manifest) when is_list(manifest) do
    case Keyword.keyword?(manifest) do
      true -> manifest |> Map.new() |> validate()
      false -> {:error, {:invalid_manifest, manifest}}
    end
  end

  def validate(manifest) when is_map(manifest) do
    with :ok <- validate_keys(manifest),
         :ok <- validate_api(Map.get(manifest, :api, 2)),
         :ok <- validate_id(Map.get(manifest, :id)),
         :ok <- validate_version(Map.get(manifest, :version)),
         {:ok, requires} <- normalize_requires(Map.get(manifest, :requires, [])),
         :ok <- validate_declarations(manifest),
         {:ok, capabilities} <- normalize_capabilities(Map.get(manifest, :capabilities, [])),
         :ok <- validate_metadata(Map.get(manifest, :metadata, %{})) do
      {:ok,
       struct!(Manifest, %{
         api: 2,
         id: manifest.id,
         version: manifest.version,
         requires: requires,
         services: Map.get(manifest, :services, []),
         extension_points: Map.get(manifest, :extension_points, []),
         contributions: Map.get(manifest, :contributions, []),
         processes: Map.get(manifest, :processes, []),
         health_checks: Map.get(manifest, :health_checks, []),
         migrations: Map.get(manifest, :migrations, []),
         capabilities: capabilities,
         metadata: Map.get(manifest, :metadata, %{})
       })}
    end
  end

  def validate(manifest), do: {:error, {:invalid_manifest, manifest}}

  defp validate_keys(manifest) do
    case Map.keys(manifest) -- @fields do
      [] -> :ok
      unknown -> {:error, {:unknown_manifest_fields, Enum.sort(unknown)}}
    end
  end

  defp validate_api(2), do: :ok
  defp validate_api(api), do: {:error, {:unsupported_manifest_api, api}}

  defp validate_id(id) when is_binary(id) and byte_size(id) > 0 do
    case Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, id) do
      true -> :ok
      false -> {:error, {:invalid_manifest_id, id}}
    end
  end

  defp validate_id(id), do: {:error, {:invalid_manifest_id, id}}

  defp validate_version(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, _version} -> :ok
      :error -> {:error, {:invalid_manifest_version, version}}
    end
  end

  defp validate_version(version), do: {:error, {:invalid_manifest_version, version}}

  defp normalize_requires(requires) when is_list(requires) do
    requires
    |> Enum.reduce_while({:ok, []}, fn dependency, {:ok, acc} ->
      case normalize_dependency(dependency) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  defp normalize_requires(requires), do: {:error, {:invalid_manifest_requires, requires}}

  defp normalize_dependency({id, requirement}),
    do: normalize_dependency(%{id: id, requirement: requirement})

  defp normalize_dependency(%{id: id, requirement: requirement})
       when is_binary(id) and byte_size(id) > 0 and is_binary(requirement) do
    with :ok <- validate_id(id) do
      case Version.parse_requirement(requirement) do
        {:ok, _parsed} -> {:ok, %{id: id, requirement: requirement}}
        :error -> {:error, {:invalid_manifest_requirement, id, requirement}}
      end
    end
  end

  defp normalize_dependency(dependency),
    do: {:error, {:invalid_manifest_dependency, dependency}}

  defp validate_declarations(manifest) do
    Enum.reduce_while(@declaration_fields, :ok, fn field, :ok ->
      case Map.get(manifest, field, []) do
        declarations when is_list(declarations) ->
          case Enum.all?(declarations, &(is_map(&1) or Keyword.keyword?(&1))) do
            true -> {:cont, :ok}
            false -> {:halt, {:error, {:invalid_manifest_declarations, field, declarations}}}
          end

        declarations ->
          {:halt, {:error, {:invalid_manifest_declarations, field, declarations}}}
      end
    end)
  end

  defp normalize_capabilities(capabilities) when is_list(capabilities) do
    case Enum.find(capabilities, &(not valid_capability?(&1))) do
      nil -> {:ok, capabilities |> Enum.uniq() |> Enum.sort()}
      invalid -> {:error, {:invalid_manifest_capability, invalid}}
    end
  end

  defp normalize_capabilities(capabilities),
    do: {:error, {:invalid_manifest_capabilities, capabilities}}

  defp validate_metadata(metadata) when is_map(metadata), do: :ok
  defp validate_metadata(metadata), do: {:error, {:invalid_manifest_metadata, metadata}}

  defp valid_capability?(capability),
    do: is_atom(capability) and not is_nil(capability) and not is_boolean(capability)

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result({:error, _reason} = error), do: error
end
