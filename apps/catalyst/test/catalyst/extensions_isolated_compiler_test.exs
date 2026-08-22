defmodule Catalyst.Extensions.IsolatedCompilerTest do
  use ExUnit.Case, async: false

  alias Catalyst.Extensions.{IsolatedCompiler, Loader}
  alias Catalyst.Runtime.{ArtifactSet, Artifacts}

  @probe_key {__MODULE__, :candidate_probe}

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "catalyst-isolated-compiler-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    :ok = File.mkdir(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    %{directory: directory}
  end

  test "compiles external-manifest code without loading it in the active VM", %{directory: dir} do
    path = write_extension(dir, "isolated_candidate", isolated_source(), isolated_manifest())
    :persistent_term.erase(@probe_key)

    assert {:ok, result} = IsolatedCompiler.preflight(path)
    assert result.artifact["id"] =~ "artifact:"

    assert [%{"logical" => "Elixir.Catalyst.Test.IsolatedCompilerCandidate"}] =
             Enum.map(result.artifact["modules"], &Map.take(&1, ["logical"]))

    physical = result.artifact["modules"] |> hd() |> Map.fetch!("physical")
    assert_raise ArgumentError, fn -> String.to_existing_atom(physical) end

    assert [%{"id" => "test.isolated-candidate", "services" => 1}] =
             Enum.map(result.manifests, &Map.take(&1, ["id", "services"]))

    refute Code.ensure_loaded?(Catalyst.Test.IsolatedCompilerCandidate)
    assert :persistent_term.get(@probe_key, :missing) == :missing
  end

  test "terminates a compiler that exceeds its deadline", %{directory: dir} do
    source = """
    defmodule Catalyst.Test.IsolatedCompilerTimeout do
      Process.sleep(5_000)
      def marker, do: :late
    end
    """

    path = write_extension(dir, "timeout", source, manifest("IsolatedCompilerTimeout"))

    assert {:error, :isolated_compiler_timeout} =
             IsolatedCompiler.preflight(path, timeout: 100)

    refute Code.ensure_loaded?(Catalyst.Test.IsolatedCompilerTimeout)
  end

  test "terminates a compiler whose diagnostics exceed the output budget", %{directory: dir} do
    source = """
    defmodule Catalyst.Test.IsolatedCompilerOutput do
      IO.write(String.duplicate("x", 4_096))
      def marker, do: :noisy
    end
    """

    path = write_extension(dir, "output", source, manifest("IsolatedCompilerOutput"))

    assert {:error, {:isolated_compiler_output_limit, 512}} =
             IsolatedCompiler.preflight(path, output_limit: 512)

    refute Code.ensure_loaded?(Catalyst.Test.IsolatedCompilerOutput)
  end

  test "loader can require isolated preflight before local managed activation", %{directory: dir} do
    path =
      write_extension(dir, "loader", loader_source(), local_manifest("IsolatedCompilerLoader"))

    previous = Application.get_env(:catalyst, :extension_managed_preflight)
    Application.put_env(:catalyst, :extension_managed_preflight, :isolated_process)

    on_exit(fn -> restore_env(:extension_managed_preflight, previous) end)

    assert {:ok, contribution} = Loader.compile(path)
    assert %ArtifactSet{} = contribution.artifact
    on_exit(fn -> Artifacts.discard([contribution.artifact.id]) end)
  end

  test "isolated workers reject unsupported service contracts", %{directory: dir} do
    path =
      write_extension(
        dir,
        "isolated_runtime",
        loader_source(),
        manifest("IsolatedCompilerLoader")
      )

    previous = Application.get_env(:catalyst, :extension_managed_preflight)
    Application.put_env(:catalyst, :extension_managed_preflight, :isolated_process)

    on_exit(fn -> restore_env(:extension_managed_preflight, previous) end)

    assert {:error,
            {:unsupported_isolated_worker_service, {"agent", "run_engine", "default"},
             {"catalyst.agent-run-engine", 1}}, []} =
             Loader.compile(path)

    refute Code.ensure_loaded?(Catalyst.Test.IsolatedCompilerLoader)
  end

  defp isolated_source do
    """
    defmodule Catalyst.Test.IsolatedCompilerCandidate do
      :persistent_term.put(#{inspect(@probe_key)}, :loaded)
      def marker, do: :isolated
    end
    """
  end

  defp loader_source do
    """
    defmodule Catalyst.Test.IsolatedCompilerLoader do
      def marker, do: :loader
    end
    """
  end

  defp isolated_manifest do
    manifest("IsolatedCompilerCandidate")
    |> Map.put("id", "test.isolated-candidate")
  end

  defp manifest(module_suffix) do
    %{
      "api" => 2,
      "id" => "test.isolated-#{String.downcase(module_suffix)}",
      "version" => "1.0.0",
      "trust" => "isolated_worker",
      "services" => [
        %{
          "key" => ["agent", "run_engine", "default"],
          "contract" => ["catalyst.agent-run-engine", 1],
          "implementation" => "Catalyst.Test.#{module_suffix}",
          "binding" => "run"
        }
      ]
    }
  end

  defp local_manifest(module_suffix) do
    module_suffix
    |> manifest()
    |> Map.put("trust", "local_trusted")
  end

  defp write_extension(directory, name, source, manifest) do
    path = Path.join(directory, name <> ".ex")
    :ok = File.write(path, source)
    :ok = File.write(path <> ".manifest.json", Jason.encode!(manifest))
    path
  end

  defp restore_env(key, nil), do: Application.delete_env(:catalyst, key)
  defp restore_env(key, value), do: Application.put_env(:catalyst, key, value)
end
