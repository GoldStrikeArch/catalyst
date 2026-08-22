defmodule Catalyst.Tools.RuntimeGraph do
  @moduledoc """
  Read-only introspection of the active Runtime Service Graph.

  The tool reports observable managed claims and contributions. Raw module
  side effects that bypass registries remain outside this graph.
  """

  use Catalyst.Tools.Tool

  alias Catalyst.Runtime

  alias Catalyst.Runtime.{
    Artifact,
    Artifacts,
    CandidateProcesses,
    Claim,
    Contribution,
    Generation,
    Generations,
    ImplementationGuarantee,
    Lease,
    Leases,
    Resolver,
    ServiceKey
  }

  alias Catalyst.Tools.Truncate

  @impl true
  def name, do: "runtime_graph"

  @impl true
  def description do
    "Inspect active runtime services and extension contributions, including owners, " <>
      "provenance, hidden claims, source health, and graph snapshot identity."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "service" => %{
          "type" => "string",
          "description" => "Optional service key in namespace.name/slot form"
        },
        "owner" => %{
          "type" => "string",
          "description" =>
            "Optional exact owner representation, such as builtin or \"my_extension\""
        }
      },
      "required" => []
    }
  end

  @impl true
  def execute(args, ctx) do
    context = runtime_context(ctx)
    graph = Runtime.snapshot(context)
    lease_snapshot = Leases.snapshot()
    artifact_snapshot = Artifacts.snapshot()
    generations = Generations.list(lease_snapshot)

    case render(args, graph, generations, lease_snapshot, artifact_snapshot) do
      {:ok, body} ->
        {text, truncation} = Truncate.head_notice(body)

        result(text, %{
          snapshot_id: graph.snapshot_id,
          claim_count: length(graph.claims),
          contribution_count: length(graph.contributions),
          generation_count: length(generations),
          lease_count: lease_count(lease_snapshot),
          artifact_count: artifact_count(artifact_snapshot),
          process_count: generation_process_count(generations),
          capability_count: generation_declaration_count(generations, :capabilities),
          migration_count: generation_declaration_count(generations, :migrations),
          guarantee_counts:
            Enum.frequencies_by(
              graph.claims,
              &ImplementationGuarantee.classify(&1.implementation)
            ),
          truncation: truncation
        })

      {:error, reason} ->
        raise ArgumentError, "runtime graph query failed: #{inspect(reason)}"
    end
  end

  defp render(
         %{"service" => service} = args,
         graph,
         generations,
         lease_snapshot,
         artifact_snapshot
       )
       when is_binary(service) and service != "" do
    with {:ok, key} <- ServiceKey.parse(service) do
      claims = Enum.filter(graph.claims, &owner_match?(&1.owner, Map.get(args, "owner")))
      explanation = Resolver.explain(claims, key, graph.context)

      {:ok,
       render_explanation(graph, explanation, generations, lease_snapshot, artifact_snapshot)}
    end
  end

  defp render(args, graph, generations, lease_snapshot, artifact_snapshot) do
    owner = Map.get(args, "owner")
    claims = Enum.filter(graph.claims, &owner_match?(&1.owner, owner))
    contributions = Enum.filter(graph.contributions, &owner_match?(&1.owner, owner))

    {:ok,
     [
       graph_header(graph, generations, lease_snapshot, artifact_snapshot),
       "\nServices:\n",
       render_rows(claims, &claim_line/1),
       "\nContributions:\n",
       render_rows(contributions, &contribution_line/1)
     ]
     |> IO.iodata_to_binary()}
  end

  defp render_explanation(
         graph,
         explanation,
         generations,
         lease_snapshot,
         artifact_snapshot
       ) do
    [
      graph_header(graph, generations, lease_snapshot, artifact_snapshot),
      "\nResolution: ",
      inspect(explanation.status),
      "\nSelected:\n",
      render_optional_claim(explanation.selected),
      "\nHidden:\n",
      render_rows(explanation.hidden, &claim_line/1),
      "\nRejected:\n",
      render_rejections(explanation.rejected)
    ]
    |> IO.iodata_to_binary()
  end

  defp graph_header(graph, generations, lease_snapshot, artifact_snapshot) do
    [
      "Runtime graph ",
      graph.snapshot_id,
      "\nSources: ",
      inspect(graph.source_status, pretty: true),
      "\nCoverage: ",
      inspect(graph.source_metadata, pretty: true),
      "\nGenerations:\n",
      render_rows(generations, &generation_line/1),
      generation_summary(generations),
      "\nLeases:\n",
      render_lease_snapshot(lease_snapshot),
      "\nArtifacts:\n",
      render_artifact_snapshot(artifact_snapshot)
    ]
  end

  defp render_optional_claim(nil), do: "  (none)\n"
  defp render_optional_claim(%Claim{} = claim), do: claim_line(claim)

  defp render_rows([], _formatter), do: "  (none)\n"
  defp render_rows(rows, formatter), do: Enum.map_join(rows, "", formatter)

  defp render_rejections([]), do: "  (none)\n"

  defp render_rejections(rejections) do
    Enum.map_join(rejections, "", fn rejection ->
      "  - #{claim_identity(rejection.claim)} reason=#{inspect(rejection.reason)}\n"
    end)
  end

  defp claim_line(%Claim{} = claim) do
    "  - #{claim_identity(claim)} owner=#{inspect(claim.owner)} " <>
      "scope=#{inspect(claim.scope.constraints)} priority=#{claim.priority} " <>
      "binding=#{inspect(claim.binding)} " <>
      "guarantee=#{inspect(ImplementationGuarantee.classify(claim.implementation))} " <>
      "provenance=#{inspect(claim.provenance)}\n"
  end

  defp claim_identity(%Claim{} = claim) do
    logical = Catalyst.Runtime.ImplementationRef.logical(claim.implementation)
    "#{ServiceKey.to_wire(claim.key)} => #{inspect(logical)}"
  end

  defp contribution_line(%Contribution{} = contribution) do
    "  - #{contribution.point}/#{inspect(contribution.id)} " <>
      "owner=#{inspect(contribution.owner)} value=#{value_summary(contribution.value)} " <>
      "provenance=#{inspect(contribution.provenance)}\n"
  end

  defp generation_line(%Generation{} = generation) do
    "  - #{Catalyst.Runtime.ActivationId.to_wire(generation.id)} " <>
      "graph=#{Catalyst.Runtime.GenerationId.to_wire(generation.graph_id)} " <>
      "status=#{generation.status} leases=#{generation.lease_count} " <>
      "parent=#{generation_parent(generation.parent)} " <>
      "deadline=#{inspect(generation.drain_deadline)} " <>
      "timed_out=#{inspect(generation.drain_timed_out_at)} " <>
      "forced=#{inspect(generation.forced_retirement_at)} " <>
      "owners=#{inspect(generation_owners(generation))} " <>
      "processes=#{length(CandidateProcesses.list(generation.id))}/#{length(generation.candidate.processes)} " <>
      "capabilities=#{declaration_ids(generation.candidate.capabilities, :capability)} " <>
      "migrations=#{declaration_ids(generation.candidate.migrations, :id)} " <>
      "reason=#{inspect(generation.reason)}\n"
  end

  defp generation_parent(nil), do: "none"
  defp generation_parent(parent), do: Catalyst.Runtime.ActivationId.to_wire(parent)

  defp generation_summary(generations) do
    "Managed footprint: processes=#{generation_process_count(generations)} " <>
      "capabilities=#{generation_declaration_count(generations, :capabilities)} " <>
      "migrations=#{generation_declaration_count(generations, :migrations)}\n"
  end

  defp lease_line(%Lease{} = lease) do
    "  - #{Catalyst.Runtime.ActivationId.to_wire(lease.generation)} " <>
      "binding=#{lease.binding} owner=#{inspect(lease.owner)} " <>
      "acquired_at=#{DateTime.to_iso8601(lease.acquired_at)}\n"
  end

  defp artifact_line(%Artifact{} = artifact) do
    activations =
      artifact.activations
      |> Enum.map(&Catalyst.Runtime.ActivationId.to_wire/1)
      |> Enum.sort()

    modules = Catalyst.Runtime.ArtifactSet.physical_modules(artifact.set)

    "  - #{Catalyst.Runtime.ArtifactId.to_wire(artifact.id)} " <>
      "status=#{artifact.status} activations=#{inspect(activations)} " <>
      "modules=#{length(modules)} reason=#{inspect(artifact.reason)}\n"
  end

  defp render_lease_snapshot({:ok, leases}), do: render_rows(leases, &lease_line/1)
  defp render_lease_snapshot({:error, reason}), do: "  unavailable: #{inspect(reason)}\n"

  defp render_artifact_snapshot({:ok, artifacts}),
    do: render_rows(artifacts, &artifact_line/1)

  defp render_artifact_snapshot({:error, reason}),
    do: "  unavailable: #{inspect(reason)}\n"

  defp lease_count({:ok, leases}), do: length(leases)
  defp lease_count({:error, _reason}), do: :unknown

  defp artifact_count({:ok, artifacts}), do: length(artifacts)
  defp artifact_count({:error, _reason}), do: :unknown

  defp generation_process_count(generations) do
    generations
    |> Enum.map(&CandidateProcesses.list(&1.id))
    |> Enum.map(&length/1)
    |> Enum.sum()
  end

  defp generation_declaration_count(generations, field) do
    generations
    |> Enum.map(&Map.fetch!(&1.candidate, field))
    |> Enum.map(&length/1)
    |> Enum.sum()
  end

  defp generation_owners(%Generation{} = generation) do
    generation.owners
    |> Map.keys()
    |> Enum.sort()
  end

  defp declaration_ids([], _field), do: "[]"

  defp declaration_ids(declarations, field) do
    declarations
    |> Enum.map(&Map.fetch!(&1, field))
    |> Enum.sort()
    |> inspect()
  end

  defp value_summary(value) when is_binary(value), do: "<binary #{byte_size(value)} bytes>"

  defp value_summary(value) when is_map(value),
    do: inspect(value, limit: 12, printable_limit: 200)

  defp value_summary(value), do: inspect(value, limit: 12, printable_limit: 200)

  defp owner_match?(_owner, owner) when owner in [nil, ""], do: true

  defp owner_match?(owner, requested),
    do: inspect(owner) == requested or owner_label(owner) == requested

  defp owner_label(owner) when is_binary(owner), do: owner
  defp owner_label(owner) when is_atom(owner), do: Atom.to_string(owner)
  defp owner_label(owner), do: inspect(owner)

  defp runtime_context(ctx) do
    %{
      session_id: ctx[:session_id],
      metadata: %{cwd: ctx[:cwd]}
    }
  end
end
