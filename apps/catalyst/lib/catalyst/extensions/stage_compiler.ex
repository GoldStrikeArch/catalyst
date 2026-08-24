defmodule Catalyst.Extensions.StageCompiler do
  @moduledoc false

  alias Catalyst.Extensions.Loader

  @doc false
  @spec run_from_env() :: no_return()
  def run_from_env do
    {:ok, _apps} = Application.ensure_all_started(:elixir)
    {:ok, _apps} = Application.ensure_all_started(:logger)
    request = System.fetch_env!("CATALYST_EXTENSION_STAGE_REQUEST")
    response = System.fetch_env!("CATALYST_EXTENSION_STAGE_RESPONSE")

    result =
      request
      |> File.read!()
      |> :erlang.binary_to_term()
      |> compile_request()

    File.write!(response, :erlang.term_to_binary(result, compressed: 6))
    System.halt(0)
  rescue
    error ->
      write_crash_response(Exception.message(error))
      System.halt(2)
  catch
    kind, reason ->
      write_crash_response({kind, reason})
      System.halt(2)
  end

  defp compile_request(%{paths: paths, timeout: timeout}) do
    previous = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      Enum.map(paths, &compile_path(&1, timeout))
    after
      Code.compiler_options(previous)
    end
  end

  defp compile_path({source, path}, timeout) do
    task = Task.async(fn -> compile(path) end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:exit, reason}}
        nil -> {:error, :timeout}
      end

    {source, path, result}
  end

  defp compile(path) do
    path
    |> Code.compile_file()
    |> Loader.classify_compiled()
  rescue
    error -> {:error, {:compile, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:compile, {kind, reason}}}
  end

  defp write_crash_response(reason) do
    case System.get_env("CATALYST_EXTENSION_STAGE_RESPONSE") do
      nil -> :ok
      path -> File.write(path, :erlang.term_to_binary({:stage_crash, reason}))
    end
  end
end
