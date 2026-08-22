defmodule Catalyst.ExtensionManifestTest do
  use ExUnit.Case, async: true

  alias Catalyst.Extension
  alias Catalyst.Extension.Manifest
  alias Catalyst.Runtime.{ArtifactId, ImplementationRef}

  defmodule LegacyExtension do
    use Catalyst.Extension

    @impl true
    def setup(_api), do: :ok
  end

  defmodule DeclarativeExtension do
    use Catalyst.Extension, api: 2

    manifest(%{
      id: "test.declarative-extension",
      version: "1.2.3",
      capabilities: [:filesystem, :filesystem],
      metadata: %{name: "Declarative extension"}
    })

    def metadata, do: raise("API-v2 metadata callbacks must not run")
    def setup(_api), do: raise("API-v2 setup callbacks must not run")
  end

  test "normalizes a valid API-v2 manifest" do
    assert {:ok, manifest} =
             Manifest.new(
               id: "test.manifest",
               version: "2.0.0",
               requires: [{"test.base", "~> 1.0"}],
               capabilities: [:network, :network]
             )

    assert manifest.api == 2
    assert manifest.requires == [%{id: "test.base", requirement: "~> 1.0"}]
    assert manifest.capabilities == [:network]
  end

  test "rejects invalid and unknown manifest data" do
    assert {:error, {:unsupported_manifest_api, 3}} =
             Manifest.new(%{api: 3, id: "test.manifest", version: "1.0.0"})

    assert {:error, {:invalid_manifest_version, "latest"}} =
             Manifest.new(%{id: "test.manifest", version: "latest"})

    assert {:error, {:unknown_manifest_fields, [:unknown]}} =
             Manifest.new(%{id: "test.manifest", version: "1.0.0", unknown: true})

    assert {:error, {:invalid_manifest_declarations, :services, [[123]]}} =
             Manifest.new(%{id: "test.manifest", version: "1.0.0", services: [[123]]})
  end

  test "discovers persisted API metadata without invoking v2 callbacks" do
    assert Extension.api_version(LegacyExtension) == 1
    assert Extension.imperative_module?(LegacyExtension)
    refute Extension.manifest_module?(LegacyExtension)

    assert Extension.api_version(DeclarativeExtension) == 2
    refute Extension.imperative_module?(DeclarativeExtension)
    assert Extension.manifest_module?(DeclarativeExtension)
    assert Extension.extension_module?(DeclarativeExtension)

    assert {:ok, manifest} = Extension.manifest_of(DeclarativeExtension)
    assert manifest.id == "test.declarative-extension"
    assert Extension.manifests_of([LegacyExtension, DeclarativeExtension]) == [manifest]
    assert Extension.metadata_of([DeclarativeExtension]) == %{name: "Declarative extension"}
  end

  test "requires exactly one manifest from API-v2 modules" do
    module = "MissingManifest#{System.unique_integer([:positive])}"

    assert_raise CompileError, ~r/must declare manifest\/1/, fn ->
      Code.compile_string("""
      defmodule #{module} do
        use Catalyst.Extension, api: 2
      end
      """)
    end
  end

  test "digest normalization removes physical targets nested inside structs" do
    artifact = ArtifactId.new()
    first = ImplementationRef.local(:logical, :first_physical_target, artifact)
    second = ImplementationRef.local(:logical, :second_physical_target, artifact)

    first_manifest =
      Manifest.new!(%{
        id: "test.nested-implementation-ref",
        version: "1.0.0",
        metadata: %{wrapper: %URI{query: first}}
      })

    second_manifest =
      Manifest.new!(%{
        id: "test.nested-implementation-ref",
        version: "1.0.0",
        metadata: %{wrapper: %URI{query: second}}
      })

    assert Manifest.digest_term(first_manifest) == Manifest.digest_term(second_manifest)
  end
end
