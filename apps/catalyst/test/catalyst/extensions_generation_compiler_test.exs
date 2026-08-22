defmodule Catalyst.Extensions.GenerationCompilerTest do
  use ExUnit.Case, async: false

  alias Catalyst.Extensions.{GenerationCompiler, Loader}

  alias Catalyst.Runtime.{
    ArtifactSet,
    Artifacts,
    GenerationStore,
    Generations,
    ImplementationRef,
    RunEngine
  }

  @owner "generation_compiler_test"

  setup do
    :ok = Generations.clear()

    on_exit(fn ->
      :ok = Generations.clear()
    end)

    :ok
  end

  test "same logical run engine can execute through two exact physical artifacts" do
    first = compile_artifact!(:first)
    second = compile_artifact!(:second)

    assert :ok = Artifacts.register(first)
    assert :ok = Artifacts.register(second)

    [first_manifest] = GenerationCompiler.manifests(first)
    [second_manifest] = GenerationCompiler.manifests(second)

    first_ref = first_manifest.services |> hd() |> Map.fetch!(:implementation)
    second_ref = second_manifest.services |> hd() |> Map.fetch!(:implementation)

    assert %ImplementationRef{logical: logical, target: first_target} = first_ref
    assert %ImplementationRef{logical: ^logical, target: second_target} = second_ref
    assert first_target != second_target
    assert first_target.marker() == :first
    assert second_target.marker() == :second

    assert {:ok, first_generation} = Generations.install(@owner, [first_manifest])
    assert {:ok, first_resolution} = RunEngine.resolve([])
    assert {:ok, first_pinned} = RunEngine.pin(first_resolution)

    assert first_pinned.handle.logical_implementation == logical
    assert first_pinned.handle.implementation == first_target

    assert {:ok, second_generation} = Generations.install(@owner, [second_manifest])
    assert {:ok, second_resolution} = RunEngine.resolve([])
    assert {:ok, second_pinned} = RunEngine.pin(second_resolution)

    assert first_generation.graph_id == second_generation.graph_id
    assert first_generation.id != second_generation.id
    assert first_pinned.handle.implementation.marker() == :first
    assert second_pinned.handle.implementation.marker() == :second

    assert %{status: :retiring} =
             Enum.find(Generations.list(), &(&1.id == first_generation.id))

    assert GenerationStore.active_id() == second_generation.id
    assert :ok = RunEngine.release(first_pinned)
    assert :ok = RunEngine.release(second_pinned)
  end

  test "rejects nested modules instead of assigning ambiguous logical names" do
    path =
      write_source("""
      defmodule GenerationCompilerNested do
        defmodule Inner do
        end
      end
      """)

    assert {:error, :nested_or_dynamic_modules_not_supported} =
             GenerationCompiler.compile_file(path)
  end

  test "bounds permanent physical-module namespaces before creating atoms" do
    previous_budget = Application.fetch_env(:catalyst, :runtime_artifact_namespace_budget)

    Application.put_env(
      :catalyst,
      :runtime_artifact_namespace_budget,
      Artifacts.namespace_count() + 1
    )

    on_exit(fn ->
      Catalyst.EnvCase.restore_env(:runtime_artifact_namespace_budget, previous_budget)
    end)

    first =
      write_source("""
      defmodule GenerationCompilerBudgetFirst do
        def marker, do: #{System.unique_integer([:positive])}
      end
      """)

    second =
      write_source("""
      defmodule GenerationCompilerBudgetSecond do
        def marker, do: #{System.unique_integer([:positive])}
      end
      """)

    assert {:ok, artifact} = GenerationCompiler.compile_file(first)
    assert :ok = Artifacts.register(artifact)
    on_exit(fn -> Artifacts.discard([artifact.id]) end)

    assert {:error, {:artifact_namespace_budget_exhausted, _budget}} =
             GenerationCompiler.compile_file(second)
  end

  test "loads an adjacent data manifest before compiling extension source" do
    path =
      write_source("""
      defmodule GenerationCompilerExternalEngine do
        def marker, do: :external
      end
      """)

    write_manifest(path, %{
      "api" => 2,
      "id" => "test.external-generation-manifest",
      "version" => "1.0.0",
      "trust" => "local_trusted",
      "metadata" => %{"name" => "External generation manifest"},
      "services" => [
        %{
          "key" => ["agent", "run_engine", "default"],
          "contract" => ["catalyst.agent-run-engine", 1],
          "implementation" => "GenerationCompilerExternalEngine",
          "binding" => "run"
        }
      ]
    })

    assert GenerationCompiler.generation_managed_file?(path)
    assert {:ok, contribution} = Loader.compile(path)
    assert %ArtifactSet{} = artifact = contribution.artifact
    on_exit(fn -> Artifacts.discard([artifact.id]) end)

    assert contribution.ext_mods == []
    assert [manifest] = contribution.manifests
    assert manifest.id == "test.external-generation-manifest"
    assert manifest.metadata.name == "External generation manifest"

    implementation = manifest.services |> hd() |> Map.fetch!(:implementation)
    assert implementation.logical == :"Elixir.GenerationCompilerExternalEngine"
    assert implementation.target.marker() == :external
  end

  test "rejects an invalid data manifest before source code can execute" do
    sentinel =
      Path.join(
        System.tmp_dir!(),
        "catalyst-external-manifest-sentinel-#{System.unique_integer([:positive])}"
      )

    path =
      write_source("""
      File.write!(#{inspect(sentinel)}, "compiled")

      defmodule GenerationCompilerExternalSideEffect do
      end
      """)

    File.write!(Catalyst.Extension.ManifestFile.path(path), "{invalid")
    on_exit(fn -> File.rm(Catalyst.Extension.ManifestFile.path(path)) end)
    on_exit(fn -> File.rm(sentinel) end)

    assert {:error, {:invalid_external_manifest_json, _reason}} =
             GenerationCompiler.compile_file(path)

    refute File.exists?(sentinel)
  end

  test "rejects dynamic module names with a tagged error" do
    path =
      write_source("""
      defmodule Module.concat([GenerationCompilerDynamic, Target]) do
      end
      """)

    assert {:error, :nested_or_dynamic_modules_not_supported} =
             GenerationCompiler.compile_file(path)
  end

  test "rejects protocol emitters before they can escape the artifact namespace" do
    path =
      write_source("""
      defprotocol GenerationCompilerEscapedProtocol do
        def marker(value)
      end
      """)

    assert {:error, {:generation_artifact_module_emitters_not_supported, [{:defprotocol, 1}]}} =
             GenerationCompiler.compile_file(path)

    refute Code.ensure_loaded?(GenerationCompilerEscapedProtocol)
  end

  test "rejects and purges modules emitted outside the artifact mapping" do
    path =
      write_source("""
      defmodule GenerationCompilerEmitter do
        defmacro emit do
          quote do
            defmodule unquote(GenerationCompilerMacroEscape) do
            end
          end
        end
      end

      defmodule GenerationCompilerEmitterHost do
        require GenerationCompilerEmitter
        GenerationCompilerEmitter.emit()
      end
      """)

    assert {:error, {:artifact_module_mismatch, [GenerationCompilerMacroEscape], []}} =
             GenerationCompiler.compile_file(path)

    refute Code.ensure_loaded?(GenerationCompilerMacroEscape)
  end

  test "preserves ordinary aliases when rewriting artifact-local modules" do
    path =
      write_source("""
      defmodule GenerationCompilerAlias.Engine do
        def marker, do: :aliased
      end

      defmodule GenerationCompilerAlias.Extension do
        alias GenerationCompilerAlias.Engine
        use Catalyst.Extension, api: 2, code: :generation

        manifest %{
          id: "test.generation-alias",
          version: "1.0.0",
          services: [
            %{
              key: {"agent", "run_engine", "named:generation-alias"},
              contract: {"catalyst.agent-run-engine", 1},
              implementation: Engine
            }
          ]
        }
      end
      """)

    assert {:ok, artifact} = GenerationCompiler.compile_file(path)
    assert :ok = Artifacts.register(artifact)
    on_exit(fn -> Artifacts.discard([artifact.id]) end)
    assert {:ok, target} = ArtifactSet.target(artifact, GenerationCompilerAlias.Engine)
    assert target.marker() == :aliased

    [manifest] = GenerationCompiler.manifests(artifact)
    implementation = manifest.services |> hd() |> Map.fetch!(:implementation)
    assert implementation.target == target
  end

  test "recognizes an aliased generation-mode use but ignores quoted examples" do
    aliased =
      write_source("""
      defmodule GenerationCompilerAliasedUse do
        alias Catalyst.Extension
        use Extension, api: 2, code: :generation

        manifest %{id: "test.aliased-use", version: "1.0.0"}
      end
      """)

    quoted =
      write_source("""
      defmodule GenerationCompilerQuotedUse do
        @example quote do
          use Catalyst.Extension, api: 2, code: :generation
        end
      end
      """)

    assert GenerationCompiler.generation_managed_file?(aliased)
    refute GenerationCompiler.generation_managed_file?(quoted)

    assert {:error, :generation_artifact_requires_local_service, emitted} =
             Loader.compile(aliased)

    assert emitted != []
  end

  test "embedded manifests cannot claim isolated trust after compiling in the host VM" do
    path =
      write_source("""
      defmodule GenerationCompilerEmbeddedIsolatedEngine do
        def marker, do: :isolated
      end

      defmodule GenerationCompilerEmbeddedIsolatedExtension do
        use Catalyst.Extension, api: 2, code: :generation

        manifest %{
          id: "test.embedded-isolated",
          version: "1.0.0",
          trust: :isolated_worker,
          services: [
            %{
              key: {"agent", "run_engine", "default"},
              contract: {"catalyst.agent-run-engine", 1},
              implementation: GenerationCompilerEmbeddedIsolatedEngine
            }
          ]
        }
      end
      """)

    assert {:error,
            {:isolated_trust_requires_external_manifest, "test.embedded-isolated",
             :isolated_worker}, emitted} = Loader.compile(path)

    assert emitted != []
    assert Enum.all?(emitted, &(:code.is_loaded(&1) == false))
  end

  test "reuses the physical namespace for byte-identical source" do
    path =
      write_source("""
      defmodule GenerationCompilerStableArtifact do
        def marker, do: :stable
      end
      """)

    assert {:ok, first} = GenerationCompiler.compile_file(path)
    assert :ok = Artifacts.register(first)
    assert {:ok, second} = GenerationCompiler.compile_file(path)

    assert second.id == first.id
    assert second.modules == first.modules
  end

  test "candidate validation failure discards its pending artifact" do
    artifact = compile_artifact!(:rejected)
    physical = artifact |> ArtifactSet.physical_modules() |> List.first()
    assert :ok = Artifacts.register(artifact)
    [manifest] = GenerationCompiler.manifests(artifact)

    assert {:error, {:duplicate_manifest_ids, ["test.generation-compiler"]}} =
             Generations.install(@owner, [manifest, manifest])

    assert {:ok, []} = Artifacts.snapshot()
    assert :code.is_loaded(physical) == false
  end

  defp compile_artifact!(marker) do
    path =
      write_source("""
      defmodule GenerationCompilerEngine do
        def marker, do: #{inspect(marker)}
      end

      defmodule GenerationCompilerExtension do
        use Catalyst.Extension, api: 2, code: :generation

        manifest %{
          id: "test.generation-compiler",
          version: "1.0.0",
          services: [
            %{
              key: {"agent", "run_engine", "default"},
              contract: {"catalyst.agent-run-engine", 1},
              implementation: GenerationCompilerEngine
            }
          ]
        }
      end
      """)

    assert {:ok, %ArtifactSet{} = artifact} = GenerationCompiler.compile_file(path)
    artifact
  end

  defp write_source(source) do
    path =
      Path.join(
        System.tmp_dir!(),
        "catalyst-generation-compiler-#{System.unique_integer([:positive])}.exs"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp write_manifest(source_path, manifest) do
    path = Catalyst.Extension.ManifestFile.path(source_path)
    File.write!(path, Jason.encode!(manifest))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
