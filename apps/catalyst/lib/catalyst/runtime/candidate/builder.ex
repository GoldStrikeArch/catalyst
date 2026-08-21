defmodule Catalyst.Runtime.Candidate.Builder do
  @moduledoc """
  Pure construction and validation of non-activating runtime candidates.

  The builder receives manifests and any extension points supplied by the
  caller's base generation. It performs no registry reads itself, invokes no
  extension callbacks, starts no processes, and publishes no generation pointer.
  """

  alias Catalyst.Extension.Manifest

  alias Catalyst.Runtime.{
    Candidate,
    Claim,
    ContractRef,
    Contribution,
    ExtensionPoint,
    GenerationId,
    Scope,
    ServiceKey,
    Snapshot
  }

  @service_fields [:key, :contract, :implementation, :scope, :priority, :binding, :metadata]
  @extension_point_fields [
    :id,
    :cardinality,
    :contract,
    :service,
    :default_binding,
    :schema,
    :metadata
  ]
  @contribution_fields [:point, :id, :value, :scope, :metadata]
  @process_fields [:id, :child_spec, :metadata]
  @health_check_fields [:id, :module, :function, :args, :timeout, :metadata]
  @migration_fields [:id, :from, :to, :module, :function, :metadata]
  @max_health_timeout 60_000

  @doc """
  Build a deterministic candidate from one or more API-v2 manifests.

  Options:

    * `:extension_points` — base-generation points available to declarations;
    * `:available_manifests` — installed manifests satisfying dependencies;
    * `:parent` — optional parent `GenerationId`.
  """
  @spec build([Manifest.t() | map() | keyword()], keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def build(manifests, opts \\ [])

  def build(manifests, opts) when is_list(manifests) and is_list(opts) do
    with {:ok, manifests} <- normalize_manifests(manifests),
         :ok <- validate_manifest_ids(manifests),
         {:ok, available_manifests} <-
           normalize_manifests(Keyword.get(opts, :available_manifests, [])),
         :ok <- validate_dependencies(manifests, available_manifests),
         {:ok, base_points} <- normalize_base_points(Keyword.get(opts, :extension_points, [])),
         {:ok, declared_points} <- build_extension_points(manifests),
         {:ok, all_points} <- merge_extension_points(base_points, declared_points),
         {:ok, claims} <- build_claims(manifests, all_points),
         {:ok, existing_claims} <-
           normalize_existing_claims(Keyword.get(opts, :existing_claims, [])),
         :ok <- validate_claim_conflicts(claims),
         :ok <- validate_claim_conflicts(claims, existing_claims),
         {:ok, contributions} <- build_contributions(manifests, all_points),
         {:ok, existing_contributions} <-
           normalize_existing_contributions(Keyword.get(opts, :existing_contributions, [])),
         :ok <- validate_contribution_conflicts(contributions, all_points),
         :ok <-
           validate_contribution_conflicts(contributions, existing_contributions, all_points),
         {:ok, processes} <- build_processes(manifests),
         {:ok, health_checks} <- build_health_checks(manifests),
         {:ok, migrations} <- build_migrations(manifests),
         capabilities = build_capabilities(manifests),
         {:ok, parent} <- normalize_parent(Keyword.get(opts, :parent)) do
      candidate(
        manifests,
        declared_points,
        all_points,
        claims,
        contributions,
        processes,
        health_checks,
        migrations,
        capabilities,
        parent
      )
    end
  end

  def build(manifests, opts), do: {:error, {:invalid_candidate_input, manifests, opts}}

  defp normalize_manifests(manifests) do
    manifests
    |> Enum.reduce_while({:ok, []}, fn manifest, {:ok, acc} ->
      case Manifest.new(manifest) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
    |> sort_result(& &1.id)
  end

  defp validate_manifest_ids(manifests) do
    case duplicate_by(manifests, & &1.id) do
      [] -> :ok
      duplicates -> {:error, {:duplicate_manifest_ids, duplicates}}
    end
  end

  defp validate_dependencies(manifests, available_manifests) do
    with :ok <- validate_available_manifest_ids(manifests, available_manifests) do
      versions =
        (available_manifests ++ manifests)
        |> Map.new(&{&1.id, &1.version})

      manifests
      |> Enum.reduce_while(:ok, fn manifest, :ok ->
        case unsatisfied_dependency(manifest, versions) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_available_manifest_ids(_manifests, available_manifests) do
    case duplicate_by(available_manifests, & &1.id) do
      [] -> :ok
      duplicates -> {:error, {:duplicate_available_manifest_ids, duplicates}}
    end
  end

  defp unsatisfied_dependency(manifest, versions) do
    Enum.find_value(manifest.requires, :ok, fn dependency ->
      case Map.fetch(versions, dependency.id) do
        {:ok, version} ->
          requirement_result(manifest.id, dependency, version)

        :error ->
          {:error, {:missing_manifest_dependency, manifest.id, dependency.id}}
      end
    end)
  end

  defp requirement_result(manifest_id, dependency, version) do
    case Version.match?(version, dependency.requirement) do
      true -> false
      false -> {:error, {:incompatible_manifest_dependency, manifest_id, dependency, version}}
    end
  end

  defp normalize_base_points(points) when is_list(points) do
    case Enum.find(points, &(not match?(%ExtensionPoint{}, &1))) do
      nil -> {:ok, Enum.sort_by(points, & &1.id)}
      invalid -> {:error, {:invalid_base_extension_point, invalid}}
    end
  end

  defp normalize_base_points(points), do: {:error, {:invalid_base_extension_points, points}}

  defp normalize_existing_claims(claims) when is_list(claims) do
    case Enum.find(claims, &(not match?(%Claim{}, &1))) do
      nil -> {:ok, claims}
      invalid -> {:error, {:invalid_existing_claim, invalid}}
    end
  end

  defp normalize_existing_claims(claims), do: {:error, {:invalid_existing_claims, claims}}

  defp normalize_existing_contributions(contributions) when is_list(contributions) do
    case Enum.find(contributions, &(not match?(%Contribution{}, &1))) do
      nil -> {:ok, contributions}
      invalid -> {:error, {:invalid_existing_contribution, invalid}}
    end
  end

  defp normalize_existing_contributions(contributions),
    do: {:error, {:invalid_existing_contributions, contributions}}

  defp build_extension_points(manifests) do
    reduce_declarations(manifests, :extension_points, fn manifest, spec, index ->
      spec = declaration_map(spec)

      with :ok <- validate_declaration_keys(spec, @extension_point_fields),
           {:ok, point} <-
             ExtensionPoint.new(
               spec,
               manifest.id,
               manifest_provenance(manifest, :extension_point, index)
             ) do
        {:ok, point}
      else
        {:error, reason} -> declaration_error(manifest, :extension_point, index, reason)
      end
    end)
  end

  defp merge_extension_points(base_points, declared_points) do
    Enum.reduce_while(declared_points, {:ok, Map.new(base_points, &{&1.id, &1})}, fn point,
                                                                                     {:ok, points} ->
      case put_extension_point(points, point) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> map_values_result()
  end

  defp put_extension_point(points, point) do
    with :ok <- validate_point_id(points, point),
         :ok <- validate_point_service(points, point) do
      {:ok, Map.put(points, point.id, point)}
    end
  end

  defp validate_point_id(points, point) do
    case Map.fetch(points, point.id) do
      :error ->
        :ok

      {:ok, %{owner: owner}} when owner == point.owner ->
        :ok

      {:ok, existing} ->
        {:error, {:candidate_extension_point_collision, point.id, existing.owner}}
    end
  end

  defp validate_point_service(points, point) do
    collision =
      points
      |> Map.values()
      |> Enum.find(fn existing ->
        existing.id != point.id and
          point_service_identity(existing) == point_service_identity(point) and
          not is_nil(point_service_identity(point))
      end)

    case collision do
      nil -> :ok
      existing -> {:error, {:candidate_service_point_collision, existing.id, point.id}}
    end
  end

  defp point_service_identity(%ExtensionPoint{service: nil}), do: nil

  defp point_service_identity(%ExtensionPoint{
         service: service,
         contract: %ContractRef{} = contract
       }),
       do: {service, contract.id, contract.version}

  defp build_claims(manifests, points) do
    reduce_declarations(manifests, :services, fn manifest, declaration, index ->
      build_claim(manifest, declaration_map(declaration), index, points)
    end)
    |> sort_result(&Claim.stable_key/1)
  end

  defp build_claim(manifest, declaration, index, points) do
    with :ok <- validate_declaration_keys(declaration, @service_fields),
         {:ok, key} <- service_key(Map.get(declaration, :key)),
         {:ok, contract} <- contract_ref(Map.get(declaration, :contract)),
         {:ok, point} <- service_point(points, key, contract),
         {:ok, implementation} <- required_durable(declaration, :implementation),
         {:ok, scope} <- Scope.new(Map.get(declaration, :scope, :global)),
         :ok <- validate_priority(Map.get(declaration, :priority, 800)),
         :ok <- validate_binding(Map.get(declaration, :binding, point.default_binding)),
         {:ok, metadata} <- metadata(Map.get(declaration, :metadata, %{})) do
      {:ok,
       %Claim{
         key: key,
         contract: contract,
         implementation: implementation,
         owner: manifest.id,
         scope: scope,
         priority: Map.get(declaration, :priority, 800),
         binding: Map.get(declaration, :binding, point.default_binding),
         provenance: manifest_provenance(manifest, :service, index),
         health: :starting,
         metadata: metadata
       }}
    else
      {:error, reason} -> declaration_error(manifest, :service, index, reason)
    end
  end

  defp service_point(points, key, contract) do
    matches =
      Enum.filter(points, fn point ->
        ExtensionPoint.service?(point, key) and ContractRef.compatible?(point.contract, contract)
      end)

    case matches do
      [point] -> {:ok, point}
      [] -> {:error, {:unsupported_candidate_service, ServiceKey.to_wire(key), contract}}
      matches -> {:error, {:ambiguous_candidate_service, Enum.map(matches, & &1.id)}}
    end
  end

  defp validate_claim_conflicts(claims) do
    duplicates = duplicate_by(claims, &claim_identity/1)

    case duplicates do
      [] -> :ok
      conflicts -> {:error, {:candidate_claim_conflicts, conflicts}}
    end
  end

  defp validate_claim_conflicts(claims, existing) do
    case conflicts_with_existing(claims, existing, &claim_identity/1) do
      [] -> :ok
      conflicts -> {:error, {:existing_claim_conflicts, conflicts}}
    end
  end

  defp claim_identity(claim) do
    {
      ServiceKey.to_wire(claim.key),
      claim.contract,
      claim.scope.constraints,
      claim.priority
    }
  end

  defp build_contributions(manifests, points) do
    points_by_id = Map.new(points, &{&1.id, &1})

    reduce_declarations(manifests, :contributions, fn manifest, declaration, index ->
      build_contribution(manifest, declaration_map(declaration), index, points_by_id)
    end)
    |> sort_result(&Contribution.stable_key/1)
  end

  defp build_contribution(manifest, declaration, index, points) do
    with :ok <- validate_declaration_keys(declaration, @contribution_fields),
         {:ok, point_id} <- required_binary(declaration, :point),
         {:ok, point} <- fetch_point(points, point_id),
         {:ok, id} <- required_durable(declaration, :id),
         {:ok, value} <- required_value(declaration, :value),
         {:ok, value} <- ExtensionPoint.normalize_payload(point, value),
         {:ok, scope} <- Scope.new(Map.get(declaration, :scope, :global)),
         {:ok, metadata} <- metadata(Map.get(declaration, :metadata, %{})) do
      {:ok,
       %Contribution{
         point: point.id,
         id: id,
         value: value,
         owner: manifest.id,
         scope: scope,
         provenance: manifest_provenance(manifest, :contribution, index),
         metadata: metadata
       }}
    else
      {:error, reason} -> declaration_error(manifest, :contribution, index, reason)
    end
  end

  defp fetch_point(points, point_id) do
    case Map.fetch(points, point_id) do
      {:ok, point} -> {:ok, point}
      :error -> {:error, {:unsupported_candidate_extension_point, point_id}}
    end
  end

  defp validate_contribution_conflicts(contributions, points) do
    points_by_id = Map.new(points, &{&1.id, &1})

    duplicates =
      duplicate_by(contributions, &contribution_point_identity(&1, points_by_id))

    case duplicates do
      [] -> :ok
      conflicts -> {:error, {:candidate_contribution_conflicts, conflicts}}
    end
  end

  defp validate_contribution_conflicts(contributions, existing, points) do
    points_by_id = Map.new(points, &{&1.id, &1})

    case conflicts_with_existing(
           contributions,
           existing,
           &contribution_point_identity(&1, points_by_id)
         ) do
      [] -> :ok
      conflicts -> {:error, {:existing_contribution_conflicts, conflicts}}
    end
  end

  defp contribution_point_identity(contribution, points_by_id) do
    point = Map.fetch!(points_by_id, contribution.point)
    contribution_identity(contribution, point.cardinality)
  end

  defp contribution_identity(contribution, :one),
    do: {contribution.point, contribution.scope.constraints}

  defp contribution_identity(contribution, :many),
    do: {contribution.point, contribution.id, contribution.scope.constraints}

  defp build_processes(manifests) do
    reduce_declarations(manifests, :processes, fn manifest, declaration, index ->
      declaration = declaration_map(declaration)

      with :ok <- validate_declaration_keys(declaration, @process_fields),
           {:ok, id} <- required_durable(declaration, :id),
           {:ok, child_spec} <- required_durable(declaration, :child_spec),
           {:ok, metadata} <- metadata(Map.get(declaration, :metadata, %{})) do
        {:ok,
         %{
           id: id,
           child_spec: child_spec,
           owner: manifest.id,
           provenance: manifest_provenance(manifest, :process, index),
           metadata: metadata
         }}
      else
        {:error, reason} -> declaration_error(manifest, :process, index, reason)
      end
    end)
    |> unique_owned_declarations(:process)
  end

  defp build_health_checks(manifests) do
    reduce_declarations(manifests, :health_checks, fn manifest, declaration, index ->
      declaration = declaration_map(declaration)

      with :ok <- validate_declaration_keys(declaration, @health_check_fields),
           {:ok, id} <- required_durable(declaration, :id),
           {:ok, module} <- required_atom(declaration, :module),
           {:ok, function} <- required_atom(declaration, :function),
           {:ok, args} <- argument_list(Map.get(declaration, :args, [])),
           :ok <- validate_health_timeout(Map.get(declaration, :timeout, 5_000)),
           {:ok, metadata} <- metadata(Map.get(declaration, :metadata, %{})) do
        {:ok,
         %{
           id: id,
           module: module,
           function: function,
           args: args,
           timeout: Map.get(declaration, :timeout, 5_000),
           owner: manifest.id,
           provenance: manifest_provenance(manifest, :health_check, index),
           metadata: metadata
         }}
      else
        {:error, reason} -> declaration_error(manifest, :health_check, index, reason)
      end
    end)
    |> unique_owned_declarations(:health_check)
  end

  defp build_migrations(manifests) do
    reduce_declarations(manifests, :migrations, fn manifest, declaration, index ->
      declaration = declaration_map(declaration)

      with :ok <- validate_declaration_keys(declaration, @migration_fields),
           {:ok, id} <- required_durable(declaration, :id),
           {:ok, from} <- required_non_negative_integer(declaration, :from),
           {:ok, to} <- required_non_negative_integer(declaration, :to),
           :ok <- validate_migration_range(from, to),
           {:ok, module} <- required_atom(declaration, :module),
           {:ok, function} <- required_atom(declaration, :function),
           {:ok, metadata} <- metadata(Map.get(declaration, :metadata, %{})) do
        {:ok,
         %{
           id: id,
           from: from,
           to: to,
           module: module,
           function: function,
           owner: manifest.id,
           provenance: manifest_provenance(manifest, :migration, index),
           metadata: metadata
         }}
      else
        {:error, reason} -> declaration_error(manifest, :migration, index, reason)
      end
    end)
    |> unique_owned_declarations(:migration)
  end

  defp build_capabilities(manifests) do
    manifests
    |> Enum.flat_map(fn manifest ->
      Enum.map(manifest.capabilities, fn capability ->
        %{owner: manifest.id, capability: capability}
      end)
    end)
    |> Enum.sort_by(&{&1.owner, &1.capability})
  end

  defp candidate(
         manifests,
         declared_points,
         all_points,
         claims,
         contributions,
         processes,
         health_checks,
         migrations,
         capabilities,
         parent
       ) do
    manifests = Enum.sort_by(manifests, & &1.id)
    declared_points = Enum.sort_by(declared_points, & &1.id)

    digest =
      candidate_digest(%{
        parent: parent,
        manifests: manifests,
        declared_points: declared_points,
        available_points: all_points,
        claims: claims,
        contributions: contributions,
        processes: processes,
        health_checks: health_checks,
        migrations: migrations,
        capabilities: capabilities
      })

    {:ok,
     %Candidate{
       id: GenerationId.candidate(digest),
       parent: parent,
       manifests: manifests,
       claims: claims,
       extension_points: declared_points,
       contributions: contributions,
       processes: processes,
       health_checks: health_checks,
       migrations: migrations,
       capabilities: capabilities,
       digest: digest
     }}
  end

  defp candidate_digest(parts) do
    %{
      parent: parts.parent,
      manifests: Enum.map(parts.manifests, &Manifest.digest_term/1),
      extension_points: Enum.map(parts.declared_points, &point_digest_term/1),
      available_points: Enum.map(parts.available_points, &point_reference/1),
      claims: Enum.map(parts.claims, &Claim.stable_key/1),
      contributions: Enum.map(parts.contributions, &Contribution.stable_key/1),
      processes: stable_terms(parts.processes),
      health_checks: stable_terms(parts.health_checks),
      migrations: stable_terms(parts.migrations),
      capabilities: parts.capabilities
    }
    |> Snapshot.term_id()
  end

  defp point_digest_term(point) do
    point
    |> Map.from_struct()
    |> Map.drop([:resolved_schema, :handler])
  end

  defp point_reference(point) do
    %{
      id: point.id,
      owner: point.owner,
      contract: point.contract,
      service: point.service,
      cardinality: point.cardinality,
      default_binding: point.default_binding,
      schema: point.schema
    }
  end

  defp stable_terms(terms), do: Enum.sort_by(terms, &Snapshot.term_id/1)

  defp reduce_declarations(manifests, field, builder) do
    manifests
    |> Enum.reduce_while({:ok, []}, fn manifest, {:ok, acc} ->
      manifest
      |> Map.fetch!(field)
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, acc}, fn {declaration, index}, {:ok, entries} ->
        case builder.(manifest, declaration, index) do
          {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, entries} -> {:cont, {:ok, entries}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  defp declaration_map(declaration) when is_list(declaration), do: Map.new(declaration)
  defp declaration_map(declaration) when is_map(declaration), do: declaration

  defp validate_declaration_keys(declaration, allowed) do
    case Map.keys(declaration) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_declaration_fields, Enum.sort(unknown)}}
    end
  end

  defp service_key(%ServiceKey{} = key), do: {:ok, key}
  defp service_key(value) when is_binary(value), do: ServiceKey.parse(value)
  defp service_key({namespace, name}), do: ServiceKey.new(namespace, name)
  defp service_key({namespace, name, slot}), do: ServiceKey.new(namespace, name, slot)
  defp service_key(value), do: {:error, {:invalid_candidate_service_key, value}}

  defp contract_ref(%ContractRef{} = contract), do: {:ok, contract}
  defp contract_ref({id, version}), do: ContractRef.new(id, version)
  defp contract_ref(value), do: {:error, {:invalid_candidate_contract, value}}

  defp required_binary(declaration, field) do
    case Map.fetch(declaration, field) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_declaration_field, field, value}}
      :error -> {:error, {:missing_declaration_field, field}}
    end
  end

  defp required_atom(declaration, field) do
    case Map.fetch(declaration, field) do
      {:ok, value}
      when is_atom(value) and not is_nil(value) and not is_boolean(value) ->
        {:ok, value}

      {:ok, value} ->
        {:error, {:invalid_declaration_field, field, value}}

      :error ->
        {:error, {:missing_declaration_field, field}}
    end
  end

  defp required_non_negative_integer(declaration, field) do
    case Map.fetch(declaration, field) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_declaration_field, field, value}}
      :error -> {:error, {:missing_declaration_field, field}}
    end
  end

  defp required_durable(declaration, field) do
    case Map.fetch(declaration, field) do
      {:ok, nil} -> {:error, {:invalid_declaration_field, field, nil}}
      {:ok, value} -> durable_value(value, field)
      :error -> {:error, {:missing_declaration_field, field}}
    end
  end

  defp required_value(declaration, field) do
    case Map.fetch(declaration, field) do
      {:ok, value} -> durable_value(value, field)
      :error -> {:error, {:missing_declaration_field, field}}
    end
  end

  defp durable_value(value, field) do
    case runtime_specific_term(value) do
      :none -> {:ok, value}
      invalid -> {:error, {:runtime_specific_manifest_value, field, invalid}}
    end
  end

  defp runtime_specific_term(value) when is_function(value) or is_pid(value) or is_port(value),
    do: value

  defp runtime_specific_term(value) when is_reference(value), do: value

  defp runtime_specific_term(value) when is_list(value),
    do: Enum.find_value(value, :none, &runtime_term_result/1)

  defp runtime_specific_term(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> runtime_specific_term()

  defp runtime_specific_term(value) when is_map(value) do
    Enum.find_value(value, :none, fn {key, entry} ->
      runtime_term_result(key) || runtime_term_result(entry)
    end)
  end

  defp runtime_specific_term(_value), do: :none

  defp runtime_term_result(value) do
    case runtime_specific_term(value) do
      :none -> false
      invalid -> invalid
    end
  end

  defp metadata(metadata) when is_map(metadata), do: durable_value(metadata, :metadata)
  defp metadata(metadata), do: {:error, {:invalid_declaration_metadata, metadata}}

  defp argument_list(args) when is_list(args), do: durable_value(args, :args)
  defp argument_list(args), do: {:error, {:invalid_health_check_args, args}}

  defp validate_priority(priority) when is_integer(priority), do: :ok
  defp validate_priority(priority), do: {:error, {:invalid_claim_priority, priority}}

  defp validate_binding(:live), do: :ok
  defp validate_binding({:pin, lifetime}) when is_atom(lifetime), do: :ok
  defp validate_binding(binding), do: {:error, {:invalid_claim_binding, binding}}

  defp validate_health_timeout(timeout)
       when is_integer(timeout) and timeout > 0 and timeout <= @max_health_timeout,
       do: :ok

  defp validate_health_timeout(timeout), do: {:error, {:invalid_health_check_timeout, timeout}}

  defp validate_migration_range(from, to) when from != to, do: :ok
  defp validate_migration_range(from, to), do: {:error, {:invalid_migration_range, from, to}}

  defp unique_owned_declarations({:ok, declarations}, kind) do
    case duplicate_by(declarations, &{&1.owner, &1.id}) do
      [] -> {:ok, stable_terms(declarations)}
      duplicates -> {:error, {:duplicate_candidate_declarations, kind, duplicates}}
    end
  end

  defp unique_owned_declarations({:error, _reason} = error, _kind), do: error

  defp normalize_parent(nil), do: {:ok, nil}
  defp normalize_parent(%GenerationId{} = parent), do: {:ok, parent}
  defp normalize_parent(parent), do: {:error, {:invalid_candidate_parent, parent}}

  defp manifest_provenance(manifest, kind, index),
    do: {:manifest, manifest.id, manifest.version, {kind, index}}

  defp declaration_error(manifest, kind, index, reason),
    do: {:error, {:invalid_manifest_declaration, manifest.id, kind, index, reason}}

  defp duplicate_by(values, key_fun) do
    values
    |> Enum.group_by(key_fun)
    |> Enum.filter(fn {_key, entries} -> length(entries) > 1 end)
    |> Enum.map(fn {key, _entries} -> key end)
    |> Enum.sort()
  end

  defp conflicts_with_existing(values, existing, key_fun) do
    existing_keys = MapSet.new(existing, key_fun)

    values
    |> Enum.map(key_fun)
    |> Enum.filter(&MapSet.member?(existing_keys, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result({:error, _reason} = error), do: error

  defp sort_result({:ok, values}, sorter), do: {:ok, Enum.sort_by(values, sorter)}
  defp sort_result({:error, _reason} = error, _sorter), do: error

  defp map_values_result({:ok, values}),
    do: {:ok, values |> Map.values() |> Enum.sort_by(& &1.id)}

  defp map_values_result({:error, _reason} = error), do: error
end
