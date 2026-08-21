defmodule Catalyst.Runtime.Candidate.BuilderTest do
  use ExUnit.Case, async: true

  alias Catalyst.Extension.Manifest

  alias Catalyst.Runtime.{
    Candidate,
    ContractRef,
    ExtensionPoint,
    GenerationId
  }

  alias Catalyst.Runtime.Candidate.Builder

  @contract ContractRef.new!("test.run-engine", 1)

  test "builds the same inert candidate regardless of manifest order" do
    engine = manifest("test.engine", services: [service()])

    widgets =
      manifest("test.widgets",
        requires: [{"test.engine", "~> 1.0"}],
        extension_points: [widget_point()],
        contributions: [
          %{
            point: "test.widget",
            id: "elixir",
            value: %{language: "elixir"},
            metadata: %{label: "Elixir"}
          }
        ],
        capabilities: [:filesystem]
      )

    assert {:ok, %Candidate{} = first} =
             Builder.build([engine, widgets], extension_points: [run_engine_point()])

    assert {:ok, %Candidate{} = second} =
             Builder.build([widgets, engine], extension_points: [run_engine_point()])

    assert first == second
    assert first.status == :planned
    assert first.id == GenerationId.candidate(first.digest)
    assert [%{value: %{"language" => "elixir"}}] = first.contributions
    assert [%{owner: "test.widgets", capability: :filesystem}] = first.capabilities
  end

  test "rejects an exact contract mismatch" do
    incompatible = put_in(service(), [:contract], {"test.run-engine", 2})

    assert {:error,
            {:invalid_manifest_declaration, "test.engine", :service, 0,
             {:unsupported_candidate_service, "test.run_engine/default", _contract}}} =
             Builder.build(
               [manifest("test.engine", services: [incompatible])],
               extension_points: [run_engine_point()]
             )
  end

  test "rejects missing dependencies and duplicate claims" do
    dependent = manifest("test.dependent", requires: [{"test.missing", "~> 1.0"}])

    assert {:error, {:missing_manifest_dependency, "test.dependent", "test.missing"}} =
             Builder.build([dependent])

    duplicate =
      manifest("test.duplicate",
        services: [
          service(),
          Map.put(service(), :implementation, __MODULE__.OtherEngine)
        ]
      )

    assert {:error, {:candidate_claim_conflicts, [_identity]}} =
             Builder.build([duplicate], extension_points: [run_engine_point()])
  end

  test "rejects process-local terms in declarative plans" do
    process =
      manifest("test.process",
        processes: [%{id: "worker", child_spec: fn -> :not_durable end}]
      )

    assert {:error,
            {:invalid_manifest_declaration, "test.process", :process, 0,
             {:runtime_specific_manifest_value, :child_spec, function}}} =
             Builder.build([process])

    assert is_function(function)
  end

  defp manifest(id, declarations) do
    declarations
    |> Map.new()
    |> Map.merge(%{id: id, version: "1.0.0"})
    |> Manifest.new!()
  end

  defp run_engine_point do
    {:ok, point} =
      ExtensionPoint.new(
        %{
          id: "test.run_engine",
          contract: @contract,
          service: {"test", "run_engine"},
          default_binding: {:pin, :run}
        },
        :host,
        :test
      )

    point
  end

  defp widget_point do
    %{
      id: "test.widget",
      cardinality: :many,
      schema: %{
        "type" => "object",
        "required" => ["language"],
        "properties" => %{"language" => %{"type" => "string"}}
      }
    }
  end

  defp service do
    %{
      key: {"test", "run_engine", "default"},
      contract: {"test.run-engine", 1},
      implementation: __MODULE__.Engine,
      scope: :global,
      priority: 800
    }
  end
end
