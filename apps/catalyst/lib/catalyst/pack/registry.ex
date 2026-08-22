defmodule Catalyst.Pack.Registry do
  @moduledoc "Lookup and dependency validation for compiled capability packs."

  alias Catalyst.Pack.{Catalog, Manifest}

  @catalog Map.new(Catalog.all(), &{&1.id, &1})

  @doc "List compiled pack manifests in stable identifier order."
  @spec list() :: [Manifest.t()]
  def list, do: @catalog |> Map.values() |> Enum.sort_by(& &1.id)

  @doc "Fetch an allow-listed compiled pack."
  @spec fetch(String.t()) :: {:ok, Manifest.t()} | {:error, {:unknown_pack, term()}}
  def fetch(id) when is_binary(id) do
    case Map.fetch(@catalog, id) do
      {:ok, manifest} -> {:ok, manifest}
      :error -> {:error, {:unknown_pack, id}}
    end
  end

  def fetch(id), do: {:error, {:unknown_pack, id}}

  @doc "Resolve requested packs and their dependencies in dependency-first order."
  @spec resolve([String.t()]) :: {:ok, [Manifest.t()]} | {:error, term()}
  def resolve(ids) when is_list(ids) do
    ids
    |> Enum.reduce_while({:ok, {[], MapSet.new()}}, &resolve_one(&1, &2, []))
    |> case do
      {:ok, {manifests, _seen}} -> {:ok, Enum.reverse(manifests)}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve(ids), do: {:error, {:invalid_pack_ids, ids}}

  @doc "Validate that a product names only compiled packs and includes their dependencies."
  @spec validate_product_packs(%{required(:packs) => term()} | [String.t()]) ::
          :ok | {:error, term()}
  def validate_product_packs(%{packs: ids}), do: validate_product_packs(ids)

  def validate_product_packs(ids) when is_list(ids) do
    with :ok <- validate_unique_ids(ids),
         {:ok, manifests} <- fetch_requested(ids),
         :ok <- validate_declared_dependencies(manifests, MapSet.new(ids)) do
      :ok
    end
  end

  def validate_product_packs(ids), do: {:error, {:invalid_pack_ids, ids}}

  defp resolve_one(id, {:ok, {manifests, seen}}, stack) do
    cond do
      MapSet.member?(seen, id) ->
        {:cont, {:ok, {manifests, seen}}}

      id in stack ->
        {:halt, {:error, {:pack_dependency_cycle, Enum.reverse([id | stack])}}}

      true ->
        resolve_unseen(id, manifests, seen, stack)
    end
  end

  defp resolve_unseen(id, manifests, seen, stack) do
    with {:ok, manifest} <- fetch(id),
         {:ok, {manifests, seen}} <- resolve_dependencies(manifest, manifests, seen, stack) do
      {:cont, {:ok, {[manifest | manifests], MapSet.put(seen, id)}}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp resolve_dependencies(manifest, manifests, seen, stack) do
    Enum.reduce_while(manifest.dependencies, {:ok, {manifests, seen}}, fn dependency, acc ->
      with {:ok, dependency_manifest} <- fetch(dependency.id),
           true <-
             Version.match?(dependency_manifest.version, dependency.requirement) or
               {:error,
                {:incompatible_pack_dependency, manifest.id, dependency,
                 dependency_manifest.version}} do
        case resolve_one(dependency.id, acc, [manifest.id | stack]) do
          {:cont, result} -> {:cont, result}
          {:halt, error} -> {:halt, error}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_unique_ids(ids) do
    case Enum.all?(ids, &Manifest.valid_id?/1) and length(ids) == MapSet.size(MapSet.new(ids)) do
      true -> :ok
      false -> {:error, {:invalid_pack_ids, ids}}
    end
  end

  defp fetch_requested(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, manifests} ->
      case fetch(id) do
        {:ok, manifest} -> {:cont, {:ok, [manifest | manifests]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, manifests} -> {:ok, Enum.reverse(manifests)}
      error -> error
    end
  end

  defp validate_declared_dependencies(manifests, ids) do
    missing =
      for manifest <- manifests,
          dependency <- manifest.dependencies,
          not MapSet.member?(ids, dependency.id),
          do: {manifest.id, dependency.id}

    case missing do
      [] -> validate_dependency_versions(manifests)
      _missing -> {:error, {:missing_pack_dependencies, missing}}
    end
  end

  defp validate_dependency_versions(manifests) do
    case incompatible_dependencies(manifests) do
      [] -> :ok
      incompatible -> {:error, {:incompatible_pack_dependencies, incompatible}}
    end
  end

  defp incompatible_dependencies(manifests) do
    versions = Map.new(manifests, &{&1.id, &1.version})

    for manifest <- manifests,
        dependency <- manifest.dependencies,
        version = Map.fetch!(versions, dependency.id),
        not Version.match?(version, dependency.requirement),
        do: {manifest.id, dependency, version}
  end
end
