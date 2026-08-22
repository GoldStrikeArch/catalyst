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
                 release_contributions: [executable("example", "priv/bin/example")]
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

      assert {:error, {:invalid_release_contribution, _contribution}} =
               Manifest.new(%{
                 id: "valid",
                 version: "1.0.0",
                 trust: :compiled_trusted,
                 release_contributions: [
                   %{kind: :executable, id: "escape", source: "escape", target: "../escape"}
                 ]
               })

      assert {:error, {:invalid_release_contribution, _contribution}} =
               Manifest.new(%{
                 id: "valid",
                 version: "1.0.0",
                 trust: :compiled_trusted,
                 release_contributions: [%{module: NotLoaded.Builder, callback: :build}]
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

      assert {:ok, faux} = Registry.fetch("catalyst.provider.faux")
      assert [%{kind: :llm_provider, api: "faux"}] = faux.services

      assert {:ok, coding} = Registry.fetch("catalyst.tools.coding")

      assert Enum.map(coding.release_contributions, & &1.source) ==
               ~w(rg fd sd ast-grep)
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
          release_contributions: [executable("example", "priv/bin/example")]
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
               contributions: [%{pack_id: "example.pack"}],
               digest: digest
             } = ReleasePlan.aggregate([manifest])

      assert byte_size(digest) == 64
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

    test "builds a host-filtered target plan for the shipped coding agent" do
      product = Catalyst.Product.Default.spec()

      assert {:ok, plan} = ReleasePlan.for_target(product, :cli, :darwin)

      refute "catalyst.workbench.default" in plan.packs
      assert plan.product_id == "coding-agent"
      assert plan.host == :cli
      assert plan.platform == :darwin

      assert Enum.map(plan.contributions, & &1.declaration.source) ==
               ~w(rg fd sd ast-grep)

      assert {:ok, same_plan} = ReleasePlan.for_target(product, :cli, :darwin)
      assert same_plan.digest == plan.digest
    end

    test "rejects dependencies unavailable on the selected target" do
      dependency = manifest("web-only", hosts: [:web])
      feature = manifest("desktop-feature", hosts: [:desktop], dependencies: ["web-only"])
      product = %{id: "desktop", packs: ["web-only", "desktop-feature"], hosts: [:desktop]}

      assert {:error, {:unavailable_target_dependencies, [{"desktop-feature", "web-only"}]}} =
               ReleasePlan.target([dependency, feature], product, :desktop, :darwin)
    end

    test "rejects executable target collisions with pack provenance" do
      first =
        manifest("first",
          release_contributions: [executable("first", "priv/bin/shared")]
        )

      second =
        manifest("second",
          release_contributions: [executable("second", "priv/bin/shared")]
        )

      product = %{id: "desktop", packs: ["first", "second"], hosts: [:desktop]}

      assert {:error, {:release_target_collisions, [{"priv/bin/shared", ["first", "second"]}]}} =
               ReleasePlan.target([first, second], product, :desktop, :darwin)
    end

    test "rejects a host the product does not support" do
      product = Catalyst.Product.MinimalCLI.spec()

      assert {:error, {:unsupported_product_host, "minimal-cli", :desktop}} =
               ReleasePlan.for_target(product, :desktop, :darwin)
    end

    test "filters platform-specific packs before collecting contributions" do
      common = manifest("common")

      linux =
        manifest("linux-only",
          platforms: [:linux],
          release_contributions: [executable("linux-tool", "priv/bin/linux-tool")]
        )

      product = %{id: "desktop", packs: ["common", "linux-only"], hosts: [:desktop]}

      assert {:ok, plan} =
               ReleasePlan.target([common, linux], product, :desktop, :darwin)

      assert plan.packs == ["common"]
      assert plan.contributions == []
    end
  end

  defp executable(id, target),
    do: %{kind: :executable, id: id, source: id, target: target}

  defp manifest(id, opts \\ []) do
    opts
    |> Keyword.merge(id: id, version: "1.0.0", trust: :compiled_trusted)
    |> Manifest.new!()
  end
end
