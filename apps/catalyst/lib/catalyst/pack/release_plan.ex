defmodule Catalyst.Pack.ReleasePlan do
  @moduledoc """
  Deterministic release inputs aggregated from compiled pack manifests.

  Target resolution filters packs by host and platform, verifies that every
  active dependency remains available, and rejects executable target clashes.
  It copies validated data only; build tooling owns the later execution edge.
  """

  alias Catalyst.Pack.{Manifest, Registry}

  @hosts [:cli, :web, :desktop]
  @platforms [:darwin, :linux, :windows]

  @enforce_keys [:packs, :assets, :sidecars, :contributions, :digest]
  defstruct @enforce_keys ++ [product_id: nil, host: nil, platform: nil]

  @type owned_declaration :: %{pack_id: String.t(), declaration: map()}
  @type t :: %__MODULE__{
          product_id: String.t() | nil,
          host: Manifest.host() | nil,
          platform: :darwin | :linux | :windows | nil,
          packs: [String.t()],
          assets: [owned_declaration()],
          sidecars: [owned_declaration()],
          contributions: [owned_declaration()],
          digest: String.t()
        }

  @doc "Resolve pack IDs and aggregate all of their declarative release inputs."
  @spec for_packs([String.t()]) :: {:ok, t()} | {:error, term()}
  def for_packs(ids) do
    with {:ok, manifests} <- Registry.resolve(ids) do
      {:ok, aggregate(manifests)}
    end
  end

  @doc "Build the release plan for one validated product, host, and platform target."
  @spec for_target(map(), Manifest.host(), :darwin | :linux | :windows) ::
          {:ok, t()} | {:error, term()}
  def for_target(%{id: id, packs: packs, hosts: hosts} = product, host, platform)
      when is_binary(id) and is_list(packs) and is_list(hosts) do
    with :ok <- validate_target(product, host, platform),
         {:ok, manifests} <- Registry.resolve(packs) do
      target(manifests, product, host, platform)
    end
  end

  def for_target(product, host, platform),
    do: {:error, {:invalid_release_target, product, host, platform}}

  @doc "Build a target plan from an already resolved manifest set."
  @spec target([Manifest.t()], map(), Manifest.host(), :darwin | :linux | :windows) ::
          {:ok, t()} | {:error, term()}
  def target(manifests, %{id: id} = product, host, platform) when is_list(manifests) do
    with :ok <- validate_target(product, host, platform),
         {:ok, manifests} <- validate_manifests(manifests),
         active = Enum.filter(manifests, &available?(&1, host, platform)),
         :ok <- validate_active_dependencies(active),
         plan = aggregate(active, product_id: id, host: host, platform: platform),
         :ok <- validate_target_collisions(plan.contributions) do
      {:ok, plan}
    end
  end

  def target(manifests, product, host, platform),
    do: {:error, {:invalid_release_target, manifests, product, host, platform}}

  @doc "Aggregate already validated manifests without executing callbacks."
  @spec aggregate([Manifest.t()], keyword()) :: t()
  def aggregate(manifests, metadata \\ []) when is_list(manifests) and is_list(metadata) do
    payload = %{
      product_id: Keyword.get(metadata, :product_id),
      host: Keyword.get(metadata, :host),
      platform: Keyword.get(metadata, :platform),
      packs: Enum.map(manifests, & &1.id),
      assets: owned(manifests, :assets),
      sidecars: owned(manifests, :sidecars),
      contributions: owned(manifests, :release_contributions)
    }

    struct!(__MODULE__, Map.put(payload, :digest, digest(payload)))
  end

  defp validate_target(%{id: id, hosts: hosts}, host, platform) do
    cond do
      host not in @hosts -> {:error, {:invalid_release_host, host}}
      platform not in @platforms -> {:error, {:invalid_release_platform, platform}}
      host not in hosts -> {:error, {:unsupported_product_host, id, host}}
      true -> :ok
    end
  end

  defp validate_target(product, host, platform),
    do: {:error, {:invalid_release_target, product, host, platform}}

  defp validate_manifests(manifests) do
    manifests
    |> Enum.reduce_while({:ok, []}, fn manifest, {:ok, acc} ->
      case Manifest.new(manifest) do
        {:ok, manifest} -> {:cont, {:ok, [manifest | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, manifests} -> validate_manifest_ids(Enum.reverse(manifests))
      error -> error
    end
  end

  defp validate_manifest_ids(manifests) do
    ids = Enum.map(manifests, & &1.id)

    case length(ids) == MapSet.size(MapSet.new(ids)) do
      true -> {:ok, manifests}
      false -> {:error, {:duplicate_pack_ids, ids}}
    end
  end

  defp available?(manifest, host, platform) do
    host in manifest.hosts and (:any in manifest.platforms or platform in manifest.platforms)
  end

  defp validate_active_dependencies(manifests) do
    active = MapSet.new(manifests, & &1.id)

    unavailable =
      for manifest <- manifests,
          dependency <- manifest.dependencies,
          not MapSet.member?(active, dependency.id),
          do: {manifest.id, dependency.id}

    case unavailable do
      [] -> :ok
      unavailable -> {:error, {:unavailable_target_dependencies, unavailable}}
    end
  end

  defp validate_target_collisions(contributions) do
    collisions =
      contributions
      |> Enum.filter(&match?(%{declaration: %{kind: :executable}}, &1))
      |> Enum.group_by(& &1.declaration.target)
      |> Enum.filter(fn {_target, declarations} -> length(declarations) > 1 end)
      |> Enum.map(fn {target, declarations} ->
        {target, Enum.map(declarations, & &1.pack_id)}
      end)
      |> Enum.sort()

    case collisions do
      [] -> :ok
      collisions -> {:error, {:release_target_collisions, collisions}}
    end
  end

  defp owned(manifests, field) do
    for manifest <- manifests,
        declaration <- Map.fetch!(manifest, field),
        do: %{pack_id: manifest.id, declaration: declaration}
  end

  defp digest(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
