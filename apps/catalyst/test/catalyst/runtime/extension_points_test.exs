defmodule Catalyst.Runtime.ExtensionPointsTest do
  use ExUnit.Case, async: false

  import Catalyst.ExtensionsFixtures, only: [setup_extensions_dir: 0, write_ext: 2]

  alias Catalyst.{ExtensionAPI, Runtime}

  alias Catalyst.Runtime.{
    ContractRef,
    ExtensionPoints,
    Resolver,
    Scope,
    ServiceKey
  }

  @point_owner "extension_point_test_host"
  @contributor "extension_point_test_contributor"
  @other_owner "extension_point_test_other"

  setup do
    setup_extensions_dir()
    Enum.each([@point_owner, @contributor, @other_owner], &ExtensionPoints.purge_owner/1)

    on_exit(fn ->
      Enum.each([@point_owner, @contributor, @other_owner], &ExtensionPoints.purge_owner/1)
    end)

    :ok
  end

  test "file-backed point hosts and contributors retain owner lifecycle semantics" do
    host_path =
      write_ext(
        "generic_point_host",
        """
        defmodule Catalyst.Ext.GenericPointHost do
          use Catalyst.Extension

          @impl true
          def setup(api) do
            Catalyst.ExtensionAPI.define_extension_point(api,
              id: "test.file_widget",
              cardinality: :many
            )
          end
        end
        """
      )

    contributor_path =
      write_ext(
        "generic_point_contributor",
        """
        defmodule Catalyst.Ext.GenericPointContributor do
          use Catalyst.Extension

          @impl true
          def setup(api) do
            Catalyst.ExtensionAPI.contribute(
              api,
              "test.file_widget",
              %{"label" => "from file"},
              id: "file-widget"
            )
          end
        end
        """
      )

    on_exit(fn ->
      Catalyst.Extensions.uninstall("generic_point_contributor")
      Catalyst.Extensions.uninstall("generic_point_host")
    end)

    assert {:ok, _summary} = Catalyst.Extensions.load_file(host_path)
    assert {:ok, _summary} = Catalyst.Extensions.load_file(contributor_path)

    assert Enum.any?(
             ExtensionPoints.list_contributions(),
             &(&1.point == "test.file_widget" and &1.owner == "generic_point_contributor")
           )

    assert :ok = Catalyst.Extensions.uninstall("generic_point_host")

    refute Enum.any?(
             ExtensionPoints.list_contributions(),
             &(&1.point == "test.file_widget")
           )

    assert {:ok, _summary} = Catalyst.Extensions.load_file(host_path)

    assert Enum.any?(
             ExtensionPoints.list_contributions(),
             &(&1.point == "test.file_widget" and &1.owner == "generic_point_contributor")
           )
  end

  test "extensions define and contribute to schema-validated points" do
    host = ExtensionAPI.new(@point_owner)
    contributor = ExtensionAPI.new(@contributor)

    assert :ok =
             ExtensionAPI.define_extension_point(host, %{
               id: "test.widget",
               cardinality: :many,
               schema: %{
                 "type" => "object",
                 "required" => ["label"],
                 "properties" => %{"label" => %{"type" => "string"}}
               }
             })

    assert :ok =
             ExtensionAPI.contribute(
               contributor,
               "test.widget",
               %{"label" => "Inspector"},
               id: "inspector"
             )

    assert [%{point: "test.widget", id: "inspector", owner: @contributor}] =
             Enum.filter(ExtensionPoints.list_contributions(), &(&1.point == "test.widget"))

    graph = Runtime.snapshot()

    assert graph.source_status.extension_points == :ready

    assert Enum.any?(
             graph.contributions,
             &(&1.point == "runtime.extension_point" and &1.id == "test.widget")
           )

    assert Enum.any?(
             graph.contributions,
             &(&1.point == "test.widget" and &1.id == "inspector")
           )
  end

  test "invalid contributions and unknown points return tagged errors" do
    api = ExtensionAPI.new(@point_owner)

    assert {:error, {:unsupported_extension_point, "missing.point"}} =
             ExtensionAPI.contribute(api, "missing.point", %{}, id: "missing")

    assert :ok =
             ExtensionAPI.define_extension_point(api, %{
               id: "test.required",
               schema: %{
                 "type" => "object",
                 "required" => ["name"]
               }
             })

    assert {:error, {:invalid_contribution, "test.required", _errors}} =
             ExtensionAPI.contribute(api, "test.required", %{}, id: "invalid")
  end

  test "point ownership collisions do not replace the accepted declaration" do
    first = ExtensionAPI.new(@point_owner)
    second = ExtensionAPI.new(@other_owner)

    assert :ok =
             ExtensionAPI.define_extension_point(first, %{
               id: "test.owned",
               cardinality: :many
             })

    assert {:error,
            {:owner_collision, :extension_point, "test.owned", @point_owner, @other_owner}} =
             ExtensionAPI.define_extension_point(second, %{
               id: "test.owned",
               cardinality: :one
             })

    assert {:ok, %{owner: @point_owner, cardinality: :many}} =
             ExtensionPoints.fetch("test.owned")
  end

  test "dependent contributions are hidden while their defining point is absent" do
    host = ExtensionAPI.new(@point_owner)
    contributor = ExtensionAPI.new(@contributor)

    assert :ok =
             ExtensionAPI.define_extension_point(host, %{
               id: "test.recoverable",
               cardinality: :many
             })

    assert :ok =
             ExtensionAPI.contribute(contributor, "test.recoverable", %{value: 1}, id: "entry")

    assert Enum.any?(ExtensionPoints.list_contributions(), &(&1.point == "test.recoverable"))

    assert :ok = ExtensionPoints.purge_owner(@point_owner)
    refute Enum.any?(ExtensionPoints.list_contributions(), &(&1.point == "test.recoverable"))

    assert :ok =
             ExtensionAPI.define_extension_point(host, %{
               id: "test.recoverable",
               cardinality: :many
             })

    assert Enum.any?(ExtensionPoints.list_contributions(), &(&1.point == "test.recoverable"))
  end

  test "extension-defined service points accept scoped claims for generic resolution" do
    host = ExtensionAPI.new(@point_owner)
    contributor = ExtensionAPI.new(@contributor)
    contract = ContractRef.new!("test.engine", 1)
    key = ServiceKey.new!("test", "engine")

    assert :ok =
             ExtensionAPI.define_extension_point(host, %{
               id: "test.engine",
               cardinality: :many,
               contract: contract,
               service: {"test", "engine"},
               default_binding: {:pin, :run}
             })

    assert :ok =
             ExtensionAPI.claim(contributor, key, TestEngine,
               scope: [workspace_id: "workspace-1"],
               priority: 900
             )

    graph = Runtime.snapshot(workspace_id: "workspace-1")

    assert {:ok, resolution} =
             Resolver.resolve(graph.claims, key, graph.context, contract: contract)

    assert resolution.claim.implementation == TestEngine
    assert resolution.claim.owner == @contributor
    assert resolution.claim.binding == {:pin, :run}
    assert resolution.claim.scope == Scope.new!(workspace_id: "workspace-1")
  end

  test "managed run-engine claims reject scopes the current workflow adapter cannot enforce" do
    api = ExtensionAPI.new(@contributor)
    key = ServiceKey.new!("agent", "run_engine", "scoped")

    assert {:error, {:unsupported_run_engine_claim, claim}} =
             ExtensionAPI.claim(api, key, Catalyst.Agent.Loop,
               scope: [workspace_id: "workspace-1"]
             )

    assert claim.scope == Scope.new!(workspace_id: "workspace-1")
  end
end
