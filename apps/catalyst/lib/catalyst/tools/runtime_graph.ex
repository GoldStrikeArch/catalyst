defmodule Catalyst.Tools.RuntimeGraph do
  @moduledoc """
  Read-only introspection of the active Runtime Service Graph.

  The tool reports observable managed claims and contributions. Raw module
  side effects that bypass registries remain outside this graph.
  """

  use Catalyst.Tools.Tool

  alias Catalyst.Runtime
  alias Catalyst.Runtime.{Claim, Contribution, Resolver, ServiceKey}
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

    case render(args, graph) do
      {:ok, body} ->
        {text, truncation} = Truncate.head_notice(body)

        result(text, %{
          snapshot_id: graph.snapshot_id,
          claim_count: length(graph.claims),
          contribution_count: length(graph.contributions),
          truncation: truncation
        })

      {:error, reason} ->
        raise ArgumentError, "runtime graph query failed: #{inspect(reason)}"
    end
  end

  defp render(%{"service" => service}, graph) when is_binary(service) and service != "" do
    with {:ok, key} <- ServiceKey.parse(service) do
      explanation = Resolver.explain(graph.claims, key, graph.context)
      {:ok, render_explanation(graph, explanation)}
    end
  end

  defp render(args, graph) do
    owner = Map.get(args, "owner")
    claims = Enum.filter(graph.claims, &owner_match?(&1.owner, owner))
    contributions = Enum.filter(graph.contributions, &owner_match?(&1.owner, owner))

    {:ok,
     [
       graph_header(graph),
       "\nServices:\n",
       render_rows(claims, &claim_line/1),
       "\nContributions:\n",
       render_rows(contributions, &contribution_line/1)
     ]
     |> IO.iodata_to_binary()}
  end

  defp render_explanation(graph, explanation) do
    [
      graph_header(graph),
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

  defp graph_header(graph) do
    [
      "Runtime graph ",
      graph.snapshot_id,
      "\nSources: ",
      inspect(graph.source_status, pretty: true),
      "\nCoverage: ",
      inspect(graph.source_metadata, pretty: true)
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
      "binding=#{inspect(claim.binding)} provenance=#{inspect(claim.provenance)}\n"
  end

  defp claim_identity(%Claim{} = claim) do
    "#{ServiceKey.to_wire(claim.key)} => #{inspect(claim.implementation)}"
  end

  defp contribution_line(%Contribution{} = contribution) do
    "  - #{contribution.point}/#{inspect(contribution.id)} " <>
      "owner=#{inspect(contribution.owner)} value=#{value_summary(contribution.value)} " <>
      "provenance=#{inspect(contribution.provenance)}\n"
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
