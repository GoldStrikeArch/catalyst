defmodule Catalyst.PackTest do
  use ExUnit.Case, async: true

  alias Catalyst.Pack.{Manifest, Registry, ReleasePlan}

  describe "manifest validation" do
    test "accepts bounded declarative metadata" do
      assert {:ok, manifest} =
               Manifest.new(%{
                 id: "example.pack",
                 version: "1.2.3",
                 trust: :isolated_worker,
                 dependencies: [
                   %{id: "catalyst.meta-runtime", requirement: ">= 0.1.0 and < 1.0.0"}
                 ],
                 hosts: [:cli],
                 platforms: [:linux],
                 assets: [%{source: "priv/editor.js", target: "editor.js"}],
                 sidecars: [%{id: "language-server", protocol: 1}],
                 release_contributions: [%{kind: :application, name: :example}]
               })

      assert manifest.id == "example.pack"
      assert manifest.trust == :isolated_worker

      assert manifest.dependencies == [
               %{id: "catalyst.meta-runtime", requirement: ">= 0.1.0 and < 1.0.0"}
             ]
    end

    test "rejects invalid identities, trust, and executable declarations" do
      assert {:error, {:invalid_pack_id, "Invalid Pack"}} =
               Manifest.new(%{id: "Invalid Pack", version: "1.0.0", trust: :compiled_trusted})

      assert {:error, {:invalid_pack_trust, :sandboxed}} =
               Manifest.new(%{id: "valid", version: "1.0.0", trust: :sandboxed})

      assert {:error, {:invalid_pack_field, :processes, _values}} =
               Manifest.new(%{
                 id: "valid",
                 version: "1.0.0",
                 trust: :compiled_trusted,
                 processes: [%{start: fn -> :ok end}]
               })
    end
  end

  describe "compiled catalog" do
    test "contains every pack selected by a shipped product" do
      for profile <- [
            Catalyst.Product.Default,
            Catalyst.Product.MinimalCLI,
            Catalyst.Product.IDE
          ] do
        assert :ok = profile.spec() |> Registry.validate_product_packs()
      end
    end

    test "rejects unknown, duplicate, and incomplete product selections" do
      assert {:error, {:unknown_pack, "unknown.pack"}} =
               Registry.validate_product_packs(["unknown.pack"])

      assert {:error, {:invalid_pack_ids, ["catalyst.meta-runtime", "catalyst.meta-runtime"]}} =
               Registry.validate_product_packs([
                 "catalyst.meta-runtime",
                 "catalyst.meta-runtime"
               ])

      assert {:error,
              {:missing_pack_dependencies, [{"catalyst.agent.default", "catalyst.meta-runtime"}]}} =
               Registry.validate_product_packs(["catalyst.agent.default"])
    end

    test "resolves transitive dependencies before requested packs" do
      assert {:ok, manifests} = Registry.resolve(["catalyst.ide.core"])

      assert Enum.map(manifests, & &1.id) == [
               "catalyst.meta-runtime",
               "catalyst.agent.default",
               "catalyst.workbench.default",
               "catalyst.ide.core"
             ]
    end
  end

  describe "release aggregation" do
    test "collects declarative inputs with pack provenance and invokes nothing" do
      manifest =
        Manifest.new!(%{
          id: "example.pack",
          version: "1.0.0",
          trust: :compiled_trusted,
          assets: [%{source: "priv/app.js", target: "app.js"}],
          sidecars: [%{module: NotLoaded.Sidecar, callback: :start}],
          release_contributions: [%{module: NotLoaded.Builder, callback: :build}]
        })

      assert %ReleasePlan{
               packs: ["example.pack"],
               assets: [
                 %{
                   pack_id: "example.pack",
                   declaration: %{source: "priv/app.js", target: "app.js"}
                 }
               ],
               sidecars: [%{pack_id: "example.pack"}],
               contributions: [%{pack_id: "example.pack"}]
             } = ReleasePlan.aggregate([manifest])
    end

    test "catalog plans include dependencies exactly once" do
      assert {:ok, plan} =
               ReleasePlan.for_packs([
                 "catalyst.ide.core",
                 "catalyst.agent.default"
               ])

      assert plan.packs == [
               "catalyst.meta-runtime",
               "catalyst.agent.default",
               "catalyst.workbench.default",
               "catalyst.ide.core"
             ]
    end
  end
end
