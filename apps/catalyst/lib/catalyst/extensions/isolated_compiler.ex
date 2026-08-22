defmodule Catalyst.Extensions.IsolatedCompiler do
  @moduledoc """
  Preflights generation-managed extension code in a disposable Elixir VM.

  The worker receives only paths, compiles the source and adjacent data
  manifest, writes bounded JSON metadata, and exits. Candidate modules, atoms,
  processes, and ETS tables therefore never enter the active Catalyst VM.

  This is process isolation, not an OS sandbox: compile-time code still has the
  worker user's filesystem and network access.
  """

  alias Catalyst.Extension.ManifestFile
  alias Catalyst.Runtime.{ArtifactId, ArtifactSet}

  @default_timeout 30_000
  @default_output_bytes 64 * 1024
  @default_response_bytes 256 * 1024

  @typedoc "Bounded, wire-safe metadata returned by the disposable compiler."
  @type result :: %{
          artifact: map(),
          manifests: [map()],
          diagnostics: binary()
        }

  @doc """
  Compile and inspect one externally manifested source in a disposable VM.

  `:timeout`, `:output_limit`, and `:response_limit` bound the worker. The
  executable defaults to `elixir` on `PATH` and may be set with the
  `:isolated_compiler_executable` application environment key.
  """
  @spec preflight(Path.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def preflight(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with true <- ManifestFile.exists?(path) || {:error, :external_manifest_required},
         {:ok, executable} <- executable() do
      run(executable, Path.expand(path), opts)
    end
  end

  defp run(executable, path, opts) do
    directory = temp_directory()
    response_path = Path.join(directory, "response.json")

    with :ok <- File.mkdir(directory) do
      try do
        with {:ok, port} <- open_port(executable, path, response_path, response_limit(opts)) do
          collect(
            port,
            output_limit(opts),
            timeout(opts),
            response_path,
            response_limit(opts)
          )
        end
      after
        File.rm_rf(directory)
      end
    else
      {:error, reason} -> {:error, {:isolated_compiler_temp_failed, reason}}
    end
  end

  defp open_port(executable, path, response_path, response_limit) do
    args =
      ["--erl", "+S 1:1 +SDcpu 1 +SDio 1"] ++
        code_path_args() ++
        [
          "-e",
          "Catalyst.Extensions.IsolatedCompiler.Worker.main()",
          "--",
          path,
          response_path,
          Integer.to_string(response_limit)
        ]

    {:ok,
     Port.open(
       {:spawn_executable, executable},
       [:binary, :exit_status, :stderr_to_stdout, :hide, :use_stdio, args: args]
     )}
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:isolated_compiler_start_failed, Exception.message(error)}}
  end

  defp collect(port, output_limit, timeout, response_path, response_limit) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, output_limit, output_limit, deadline, response_path, response_limit, [])
  end

  defp collect(port, limit, remaining, deadline, response_path, response_limit, output) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when byte_size(data) <= remaining ->
        collect(
          port,
          limit,
          remaining - byte_size(data),
          deadline,
          response_path,
          response_limit,
          [data | output]
        )

      {^port, {:data, _data}} ->
        terminate(port)
        {:error, {:isolated_compiler_output_limit, limit}}

      {^port, {:exit_status, 0}} ->
        decode_response(response_path, response_limit, diagnostics(output))

      {^port, {:exit_status, status}} ->
        {:error, {:isolated_compiler_exit, status, diagnostics(output)}}
    after
      wait ->
        terminate(port)
        {:error, :isolated_compiler_timeout}
    end
  end

  defp decode_response(path, limit, diagnostics) do
    with {:ok, %{size: size, type: :regular}} when size <= limit <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, decoded} <- Jason.decode(bytes) do
      normalize_response(decoded, diagnostics)
    else
      {:ok, %{size: size}} when size > limit ->
        {:error, {:isolated_compiler_response_limit, limit}}

      {:ok, _stat} ->
        {:error, :isolated_compiler_invalid_response}

      {:error, reason} ->
        {:error, {:isolated_compiler_response_failed, reason}}
    end
  end

  defp normalize_response(
         %{
           "protocol" => 1,
           "status" => "ok",
           "artifact" => %{"id" => id} = artifact,
           "manifests" => manifests
         },
         diagnostics
       )
       when is_binary(id) and is_list(manifests) do
    {:ok, %{artifact: artifact, manifests: manifests, diagnostics: diagnostics}}
  end

  defp normalize_response(
         %{"protocol" => 1, "status" => "error", "reason" => reason},
         diagnostics
       )
       when is_binary(reason),
       do: {:error, {:isolated_compile_failed, reason, diagnostics}}

  defp normalize_response(_response, _diagnostics),
    do: {:error, :isolated_compiler_invalid_response}

  defp terminate(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp executable do
    case Application.get_env(:catalyst, :isolated_compiler_executable) ||
           System.find_executable("elixir") do
      nil -> {:error, :elixir_executable_not_found}
      path when is_binary(path) -> {:ok, path}
      path -> {:error, {:invalid_isolated_compiler_executable, path}}
    end
  end

  defp code_path_args do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&["-pa", &1])
  end

  defp diagnostics(output), do: output |> Enum.reverse() |> IO.iodata_to_binary()

  defp temp_directory do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(System.tmp_dir!(), "catalyst-isolated-compiler-#{suffix}")
  end

  defp timeout(opts),
    do:
      positive_option(
        opts,
        :timeout,
        configured_positive(:isolated_compiler_timeout, @default_timeout)
      )

  defp output_limit(opts), do: positive_option(opts, :output_limit, output_limit())

  defp response_limit(opts),
    do:
      positive_option(
        opts,
        :response_limit,
        configured_positive(:isolated_compiler_response_bytes, @default_response_bytes)
      )

  defp output_limit do
    configured_positive(:isolated_compiler_output_bytes, @default_output_bytes)
  end

  defp configured_positive(key, default) do
    case Application.get_env(:catalyst, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  @doc false
  @spec expected_artifact?(result(), ArtifactSet.t()) :: boolean()
  def expected_artifact?(%{artifact: expected}, %ArtifactSet{} = actual) do
    actual = artifact_metadata(actual)

    Map.take(expected, ["id", "modules"]) == Map.take(actual, ["id", "modules"])
  end

  @doc false
  @spec artifact_metadata(ArtifactSet.t()) :: map()
  def artifact_metadata(%ArtifactSet{} = artifact) do
    modules =
      artifact.modules
      |> Enum.map(fn {logical, physical} ->
        %{"logical" => Atom.to_string(logical), "physical" => Atom.to_string(physical)}
      end)
      |> Enum.sort_by(& &1["logical"])

    beams =
      artifact.beams
      |> Enum.map(fn {module, beam} ->
        %{
          "module" => Atom.to_string(module),
          "bytes" => byte_size(beam),
          "sha256" => Base.encode16(:crypto.hash(:sha256, beam), case: :lower)
        }
      end)
      |> Enum.sort_by(& &1["module"])

    %{"id" => ArtifactId.to_wire(artifact.id), "modules" => modules, "beams" => beams}
  end
end
