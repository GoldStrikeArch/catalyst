defmodule Catalyst.Runtime.ExtensionPoints do
  @moduledoc """
  Process-free registry for extensible extension-point declarations.

  Host subsystems register stable handlers while retaining their own storage and
  purge logic. Extension-defined points use generic owner-scoped storage. Point
  removal hides dependent entries without deleting entries owned by other
  extensions, allowing them to become active again if a compatible point returns.
  """

  alias Catalyst.ExtensionAPI
  alias Catalyst.Extension.Manifest

  alias Catalyst.Runtime.{
    Claim,
    Context,
    ContractRef,
    Contribution,
    ExtensionPoint,
    GenerationStore,
    Scope,
    ServiceKey
  }

  @state_key {__MODULE__, :state}
  @state_lock {__MODULE__, :state_lock}

  @type state :: %{
          points: %{optional(String.t()) => ExtensionPoint.t()},
          contributions: %{optional(term()) => Contribution.t()},
          claims: %{optional(term()) => Claim.t()}
        }

  @doc "Register or refresh a host-owned extension point and activation handler."
  @spec register_host(map() | keyword(), ExtensionPoint.handler() | nil, term()) ::
          :ok | {:error, term()}
  def register_host(spec, handler, owner \\ :host) do
    with {:ok, point} <- ExtensionPoint.new(spec, owner, {:host, owner}, handler) do
      put_point(point)
    end
  end

  @doc "Define an owner-scoped declarative extension point."
  @spec define(ExtensionAPI.t(), map() | keyword()) :: :ok | {:error, term()}
  def define(%ExtensionAPI{owner: owner}, spec) do
    with {:ok, point} <-
           ExtensionPoint.new(spec, owner, {:extension, owner, :extension_point}) do
      put_point(point)
    end
  end

  @doc "Contribute a value through a declared extension point."
  @spec contribute(ExtensionAPI.t(), String.t(), term(), keyword()) :: term()
  def contribute(%ExtensionAPI{} = api, point_id, value, opts) when is_list(opts) do
    with {:ok, point} <- fetch(point_id),
         {:ok, value} <- ExtensionPoint.normalize_payload(point, value),
         {:ok, contribution} <- build_contribution(api, point, value, opts),
         :ok <- validate_managed_contribution(point, contribution) do
      activate_contribution(api, point, contribution, opts)
    end
  end

  @doc "Claim a logical service through the point that declares its service family."
  @spec claim(ExtensionAPI.t(), ServiceKey.t(), term(), keyword()) :: term()
  def claim(%ExtensionAPI{} = api, %ServiceKey{} = key, implementation, opts)
      when is_list(opts) do
    with {:ok, point} <- service_point(key, Keyword.get(opts, :contract)),
         {:ok, claim} <- build_claim(api, point, key, implementation, opts),
         :ok <- validate_managed_claim(claim) do
      activate_claim(api, point, claim, opts)
    end
  end

  @doc "Fetch one currently declared extension point."
  @spec fetch(String.t()) :: {:ok, ExtensionPoint.t()} | {:error, term()}
  def fetch(id) when is_binary(id) do
    case Map.fetch(combined_state().points, id) do
      {:ok, point} -> {:ok, point}
      :error -> {:error, {:unsupported_extension_point, id}}
    end
  end

  def fetch(id), do: {:error, {:invalid_extension_point_id, id}}

  @doc "List extension points in stable identifier order."
  @spec list_points() :: [ExtensionPoint.t()]
  def list_points do
    combined_state().points
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  @doc "List host and imperative extension points available to candidate planning."
  @spec base_points() :: [ExtensionPoint.t()]
  def base_points do
    state().points
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  @doc "List active generic contributions in stable order."
  @spec list_contributions() :: [Contribution.t()]
  def list_contributions do
    combined_state()
    |> active_contributions()
  end

  @doc "List active imperative contributions available to candidate planning."
  @spec base_contributions() :: [Contribution.t()]
  def base_contributions do
    state()
    |> active_contributions()
  end

  @doc "List active generic service claims in stable order."
  @spec list_claims() :: [Claim.t()]
  def list_claims do
    combined_state()
    |> active_claims()
  end

  @doc "List active imperative claims available to candidate planning."
  @spec base_claims() :: [Claim.t()]
  def base_claims do
    state()
    |> active_claims()
  end

  @doc "Remove point declarations and generic entries owned by `owner`."
  @spec purge_owner(term()) :: :ok
  def purge_owner(owner) do
    update(fn current ->
      %{
        points: Map.reject(current.points, fn {_id, point} -> point.owner == owner end),
        contributions:
          Map.reject(current.contributions, fn {_key, contribution} ->
            contribution.owner == owner
          end),
        claims: Map.reject(current.claims, fn {_key, claim} -> claim.owner == owner end)
      }
    end)
  end

  @doc "Export generic points, contributions, and claims to the Runtime Graph."
  @spec snapshot(Context.t()) ::
          {:ok, %{claims: [Claim.t()], contributions: [Contribution.t()], metadata: map()}}
  def snapshot(%Context{}) do
    current = combined_state()
    active_contributions = active_contributions(current)
    active_claims = active_claims(current)
    generation = GenerationStore.active_id()

    {:ok,
     %{
       claims: active_claims,
       contributions: point_contributions(current.points) ++ active_contributions,
       metadata: %{
         extension_points: map_size(current.points),
         generic_contributions: length(active_contributions),
         generic_claims: length(active_claims),
         hidden_orphans: orphan_count(current, active_contributions, active_claims),
         active_generation: generation && Catalyst.Runtime.ActivationId.to_wire(generation)
       }
     }}
  end

  defp put_point(%ExtensionPoint{} = point) do
    update_result(fn current ->
      validation_points = put_managed_points(current.points, managed_points())

      with :ok <- validate_point_owner(validation_points, point),
           :ok <- validate_service_identity(validation_points, point) do
        {:ok, %{current | points: Map.put(current.points, point.id, point)}}
      else
        {:error, reason} -> {{:error, reason}, current}
      end
    end)
  end

  defp validate_point_owner(points, point) do
    case Map.fetch(points, point.id) do
      :error ->
        :ok

      {:ok, existing} ->
        case same_lifecycle_owner?(existing.owner, point.owner) do
          true ->
            :ok

          false ->
            {:error, {:owner_collision, :extension_point, point.id, existing.owner, point.owner}}
        end
    end
  end

  defp validate_service_identity(points, point) do
    collision =
      points
      |> Map.values()
      |> Enum.find(fn existing ->
        existing.id != point.id and service_identity(existing) == service_identity(point) and
          not is_nil(service_identity(point))
      end)

    case collision do
      nil ->
        :ok

      existing ->
        case same_lifecycle_owner?(existing.owner, point.owner) do
          true ->
            :ok

          false ->
            {:error,
             {:service_point_collision, point.service, point.contract, existing.id, point.id}}
        end
    end
  end

  defp service_identity(%ExtensionPoint{service: nil}), do: nil

  defp service_identity(%ExtensionPoint{service: service, contract: %ContractRef{} = contract}),
    do: {service, contract.id, contract.version}

  defp service_point(%ServiceKey{} = key, requested_contract) do
    points =
      list_points()
      |> Enum.filter(&ExtensionPoint.service?(&1, key))
      |> filter_contract(requested_contract)

    case points do
      [point] ->
        {:ok, point}

      [] ->
        {:error, {:unsupported_service, ServiceKey.to_wire(key)}}

      points ->
        {:error, {:ambiguous_service_point, ServiceKey.to_wire(key), Enum.map(points, & &1.id)}}
    end
  end

  defp filter_contract(points, nil), do: points

  defp filter_contract(points, %ContractRef{} = requested) do
    Enum.filter(points, &ContractRef.compatible?(&1.contract, requested))
  end

  defp filter_contract(points, _invalid), do: points

  defp build_contribution(api, point, value, opts) do
    with {:ok, id} <- contribution_id(point, opts),
         {:ok, scope} <- Scope.new(Keyword.get(opts, :scope, :global)),
         {:ok, metadata} <- contribution_metadata(api, point, opts) do
      {:ok,
       %Contribution{
         point: point.id,
         id: id,
         value: value,
         owner: api.owner,
         scope: scope,
         provenance: {:extension, api.owner, {:contribution, point.id, id}},
         metadata: metadata
       }}
    end
  end

  defp contribution_id(%ExtensionPoint{handler: handler}, opts) when not is_nil(handler),
    do: {:ok, Keyword.get(opts, :id, :delegated)}

  defp contribution_id(%ExtensionPoint{cardinality: :one}, opts),
    do: {:ok, Keyword.get(opts, :id, :default)}

  defp contribution_id(%ExtensionPoint{cardinality: :many}, opts) do
    case Keyword.fetch(opts, :id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :contribution_id_required}
    end
  end

  defp contribution_metadata(api, point, opts) do
    case Keyword.get(opts, :metadata, %{}) do
      metadata when is_map(metadata) ->
        {:ok,
         Map.merge(metadata, %{
           extension_generation: api.generation,
           extension_point_owner: point.owner
         })}

      metadata ->
        {:error, {:invalid_contribution_metadata, metadata}}
    end
  end

  defp activate_contribution(
         api,
         %ExtensionPoint{handler: {module, function}},
         contribution,
         opts
       ),
       do: apply(module, function, [api, contribution, opts])

  defp activate_contribution(_api, %ExtensionPoint{} = point, contribution, _opts) do
    key = contribution_key(contribution)

    update_result(fn current ->
      case Map.fetch(current.contributions, key) do
        :error ->
          {:ok, put_in(current.contributions[key], contribution)}

        {:ok, %Contribution{owner: owner}} when owner == contribution.owner ->
          {:ok, put_in(current.contributions[key], contribution)}

        {:ok, existing} ->
          error =
            {:owner_collision, :contribution, {point.id, contribution.id}, existing.owner,
             contribution.owner}

          {{:error, error}, current}
      end
    end)
  end

  defp build_claim(api, point, key, implementation, opts) do
    with :ok <- validate_claim_contract(point, Keyword.get(opts, :contract)),
         {:ok, scope} <- Scope.new(Keyword.get(opts, :scope, :global)),
         :ok <- validate_priority(Keyword.get(opts, :priority, 800)),
         :ok <- validate_binding(Keyword.get(opts, :binding, point.default_binding)),
         {:ok, metadata} <- claim_metadata(api, point, opts) do
      {:ok,
       %Claim{
         key: key,
         contract: point.contract,
         implementation: implementation,
         owner: api.owner,
         scope: scope,
         priority: Keyword.get(opts, :priority, 800),
         binding: Keyword.get(opts, :binding, point.default_binding),
         provenance: {:extension, api.owner, {:service_claim, ServiceKey.to_wire(key)}},
         metadata: metadata
       }}
    end
  end

  defp validate_claim_contract(%ExtensionPoint{contract: contract}, nil)
       when not is_nil(contract),
       do: :ok

  defp validate_claim_contract(
         %ExtensionPoint{contract: %ContractRef{} = contract},
         %ContractRef{} = requested
       ) do
    case ContractRef.compatible?(contract, requested) do
      true -> :ok
      false -> {:error, {:incompatible_contract, requested, contract}}
    end
  end

  defp validate_claim_contract(point, requested),
    do: {:error, {:invalid_service_contract, requested, point.contract}}

  defp validate_priority(priority) when is_integer(priority), do: :ok
  defp validate_priority(priority), do: {:error, {:invalid_claim_priority, priority}}

  defp validate_binding(:live), do: :ok
  defp validate_binding({:pin, lifetime}) when is_atom(lifetime), do: :ok
  defp validate_binding(binding), do: {:error, {:invalid_claim_binding, binding}}

  defp claim_metadata(api, point, opts) do
    case Keyword.get(opts, :metadata, %{}) do
      metadata when is_map(metadata) ->
        {:ok,
         Map.merge(metadata, %{
           extension_generation: api.generation,
           extension_point: point.id,
           extension_point_owner: point.owner
         })}

      metadata ->
        {:error, {:invalid_claim_metadata, metadata}}
    end
  end

  defp activate_claim(api, %ExtensionPoint{handler: {module, function}}, claim, opts),
    do: apply(module, function, [api, claim, opts])

  defp activate_claim(_api, %ExtensionPoint{}, claim, _opts) do
    update(fn current -> put_in(current.claims[claim_key(claim)], claim) end)
  end

  defp validate_managed_contribution(point, contribution) do
    collision =
      managed_contributions()
      |> Enum.find(
        &(contribution_identity(&1, point.cardinality) ==
            contribution_identity(contribution, point.cardinality))
      )

    case collision do
      nil ->
        :ok

      existing ->
        case same_lifecycle_owner?(existing.owner, contribution.owner) do
          true ->
            :ok

          false ->
            {:error,
             {:owner_collision, :contribution, {point.id, contribution.id}, existing.owner,
              contribution.owner}}
        end
    end
  end

  defp validate_managed_claim(claim) do
    collision =
      managed_claims()
      |> Enum.find(&(claim_collision_identity(&1) == claim_collision_identity(claim)))

    case collision do
      nil ->
        :ok

      existing ->
        case same_lifecycle_owner?(existing.owner, claim.owner) do
          true ->
            :ok

          false ->
            {:error,
             {:owner_collision, :service_claim, ServiceKey.to_wire(claim.key), existing.owner,
              claim.owner}}
        end
    end
  end

  defp contribution_identity(contribution, :one),
    do: {contribution.point, contribution.scope.constraints}

  defp contribution_identity(contribution, :many),
    do: {contribution.point, contribution.id, contribution.scope.constraints}

  defp claim_collision_identity(claim) do
    {
      ServiceKey.to_wire(claim.key),
      claim.contract.id,
      claim.contract.version,
      claim.scope.constraints,
      claim.priority
    }
  end

  defp managed_points do
    case GenerationStore.active_candidate() do
      nil -> []
      candidate -> candidate.extension_points
    end
  end

  defp managed_contributions do
    case GenerationStore.active_candidate() do
      nil -> []
      candidate -> candidate.contributions
    end
  end

  defp managed_claims do
    case GenerationStore.active_candidate() do
      nil -> []
      candidate -> candidate.claims
    end
  end

  defp same_lifecycle_owner?(owner, owner), do: true

  defp same_lifecycle_owner?(managed_owner, source_owner) do
    GenerationStore.owners()
    |> Enum.any?(fn {owner, manifests} ->
      owner == source_owner and
        Enum.any?(manifests, &match?(%Manifest{id: ^managed_owner}, &1))
    end)
  end

  defp point_contributions(points) do
    points
    |> Map.values()
    |> Enum.map(fn point ->
      %Contribution{
        point: "runtime.extension_point",
        id: point.id,
        value:
          Map.take(point, [:id, :cardinality, :contract, :service, :default_binding, :schema]),
        owner: point.owner,
        scope: Scope.global(),
        provenance: point.provenance,
        metadata: point.metadata
      }
    end)
  end

  defp active_contribution(contribution, points) do
    case Map.fetch(points, contribution.point) do
      {:ok, point} ->
        case ExtensionPoint.normalize_payload(point, contribution.value) do
          {:ok, value} -> [%{contribution | value: value}]
          {:error, _reason} -> []
        end

      :error ->
        []
    end
  end

  defp active_claim?(claim, points) do
    Enum.any?(points, fn {_id, point} ->
      ExtensionPoint.service?(point, claim.key) and
        ContractRef.compatible?(point.contract, claim.contract)
    end)
  end

  defp active_contributions(current) do
    current.contributions
    |> Map.values()
    |> Enum.flat_map(&active_contribution(&1, current.points))
    |> Enum.sort_by(&Contribution.stable_key/1)
  end

  defp active_claims(current) do
    current.claims
    |> Map.values()
    |> Enum.filter(&active_claim?(&1, current.points))
    |> Enum.sort_by(&Claim.stable_key/1)
  end

  defp orphan_count(current, active_contributions, active_claims) do
    map_size(current.contributions) - length(active_contributions) +
      map_size(current.claims) - length(active_claims)
  end

  defp contribution_key(contribution),
    do: {contribution.point, contribution.id, contribution.scope.constraints}

  defp claim_key(claim) do
    {
      ServiceKey.to_wire(claim.key),
      {claim.contract.id, claim.contract.version},
      claim.owner,
      claim.scope.constraints,
      claim.priority
    }
  end

  defp update(fun) do
    :global.trans(@state_lock, fn ->
      :persistent_term.put(@state_key, fun.(state()))
      :ok
    end)
  end

  defp update_result(fun) do
    :global.trans(@state_lock, fn ->
      case fun.(state()) do
        {:ok, next} ->
          :persistent_term.put(@state_key, next)
          :ok

        {{:error, _reason} = error, _unchanged} ->
          error
      end
    end)
  end

  defp state do
    :persistent_term.get(@state_key, %{points: %{}, contributions: %{}, claims: %{}})
  end

  defp combined_state do
    current = state()

    case GenerationStore.active_candidate() do
      nil ->
        current

      candidate ->
        %{
          points: put_managed_points(current.points, candidate.extension_points),
          contributions:
            put_managed_entries(
              current.contributions,
              candidate.contributions,
              &contribution_key/1
            ),
          claims: put_managed_entries(current.claims, candidate.claims, &claim_key/1)
        }
    end
  end

  defp put_managed_points(points, managed) do
    Enum.reduce(managed, points, &Map.put(&2, &1.id, &1))
  end

  defp put_managed_entries(entries, managed, key_fun) do
    Enum.reduce(managed, entries, &Map.put(&2, key_fun.(&1), &1))
  end
end
