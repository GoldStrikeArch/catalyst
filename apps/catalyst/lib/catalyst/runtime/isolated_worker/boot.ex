defmodule Catalyst.Runtime.IsolatedWorker.Boot do
  @moduledoc false

  alias Catalyst.Contracts.PermissionPolicy.V1
  alias Catalyst.Extensions.{GenerationCompiler, IsolatedCompiler}
  alias Catalyst.Runtime.{Artifacts, ImplementationRef, IsolatedWorker.Protocol}

  @doc false
  @spec main() :: no_return()
  def main do
    protocol_io = Process.group_leader()
    Process.group_leader(self(), spawn_link(&discard_io/0))

    case System.argv() do
      [source_path, expected_artifact, max_bytes] ->
        run(protocol_io, source_path, expected_artifact, parse_limit(max_bytes))

      _args ->
        System.halt(64)
    end
  end

  defp run(protocol_io, source_path, expected_artifact, limit) do
    case compile(source_path, expected_artifact) do
      {:ok, module, artifact_id} ->
        emit(protocol_io, Protocol.ready(artifact_id, limit))
        serve(protocol_io, module, limit)

      {:error, reason} ->
        emit(protocol_io, Protocol.boot_error(reason, limit))
        System.halt(70)
    end
  end

  defp compile(source_path, expected_artifact) do
    with {:ok, _pid} <- Artifacts.start_link(),
         {:ok, artifact} <- GenerationCompiler.compile_preflight_file(source_path),
         artifact_id = IsolatedCompiler.artifact_metadata(artifact)["id"],
         true <- artifact_id == expected_artifact || {:error, :isolated_worker_artifact_changed},
         {:ok, module} <- permission_module(GenerationCompiler.manifests(artifact)) do
      {:ok, module, artifact_id}
    end
  rescue
    exception -> {:error, {:isolated_worker_compile_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:isolated_worker_compile_exit, kind, reason}}
  end

  defp permission_module(manifests) do
    services = Enum.flat_map(manifests, & &1.services)

    case Enum.filter(services, &permission_service?/1) do
      [%{implementation: implementation}] ->
        module = ImplementationRef.target(implementation)

        case function_exported?(module, :authorize, 4) do
          true -> {:ok, module}
          false -> {:error, :isolated_permission_policy_callback_missing}
        end

      services ->
        {:error, {:isolated_permission_policy_required, length(services)}}
    end
  end

  defp permission_service?(service) do
    service.key == {"agent", "permission_policy", "default"} and
      service.contract == {V1.ref().id, V1.ref().version}
  end

  defp serve(protocol_io, module, limit) do
    case IO.binread(protocol_io, :line) do
      line when is_binary(line) ->
        response = line |> Protocol.decode_request(limit) |> invoke(module)
        emit(protocol_io, response)

        serve(protocol_io, module, limit)

      _closed ->
        System.halt(0)
    end
  end

  defp invoke({:ok, id, :authorize, args}, module) do
    result = apply(module, :authorize, args)
    Protocol.response(id, result, protocol_limit())
  rescue
    exception -> Protocol.response(id, {:error, Exception.message(exception)}, protocol_limit())
  catch
    kind, reason -> Protocol.response(id, {:error, {kind, reason}}, protocol_limit())
  end

  defp invoke({:error, reason}, _module),
    do: Protocol.response(nil, {:error, reason}, protocol_limit())

  defp emit(protocol_io, {:ok, line}), do: IO.binwrite(protocol_io, line)
  defp emit(_protocol_io, {:error, _reason}), do: System.halt(74)

  defp parse_limit(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 ->
        Process.put({__MODULE__, :limit}, limit)
        limit

      _invalid ->
        System.halt(64)
    end
  end

  defp protocol_limit, do: Process.get({__MODULE__, :limit})

  defp discard_io do
    receive do
      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, :ok})
        discard_io()

      _message ->
        discard_io()
    end
  end
end
