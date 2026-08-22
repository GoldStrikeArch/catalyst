defmodule Catalyst.Extensions.IsolatedCompiler.Worker do
  @moduledoc false

  alias Catalyst.Extensions.{GenerationCompiler, IsolatedCompiler}
  alias Catalyst.Runtime.Artifacts

  @doc false
  @spec main() :: no_return()
  def main do
    case System.argv() do
      [source_path, response_path, max_bytes] ->
        response = compile(source_path)
        write_response(response_path, response, max_bytes)
        System.halt(0)

      _args ->
        System.halt(64)
    end
  end

  defp compile(source_path) do
    with true <- File.regular?(source_path <> ".manifest.json") || :external_manifest_required,
         {:ok, _pid} <- Artifacts.start_link(),
         {:ok, artifact} <- GenerationCompiler.compile_preflight_file(source_path) do
      success(artifact)
    else
      reason -> error(reason)
    end
  rescue
    exception -> error({:exception, Exception.message(exception)})
  catch
    kind, reason -> error({kind, reason})
  end

  defp success(artifact) do
    %{
      "protocol" => 1,
      "status" => "ok",
      "artifact" => IsolatedCompiler.artifact_metadata(artifact),
      "manifests" => Enum.map(artifact.manifests, &manifest_metadata/1)
    }
  end

  defp error(reason) do
    %{
      "protocol" => 1,
      "status" => "error",
      "reason" => inspect(reason, limit: 50, printable_limit: 4_096)
    }
  end

  defp manifest_metadata(manifest) do
    %{
      "id" => manifest.id,
      "version" => to_string(manifest.version),
      "trust" => Atom.to_string(manifest.trust),
      "services" => length(manifest.services)
    }
  end

  defp write_response(path, response, max_bytes) do
    with {limit, ""} <- Integer.parse(max_bytes),
         {:ok, encoded} <- Jason.encode(response),
         true <- byte_size(encoded) <= limit,
         :ok <- File.write(path, encoded) do
      :ok
    else
      _error -> System.halt(74)
    end
  end
end
