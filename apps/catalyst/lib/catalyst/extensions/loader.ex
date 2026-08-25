defmodule Catalyst.Extensions.Loader do
  @moduledoc """
  Isolated compile, classification, metadata, and setup pipeline for extension
  source files.

  Compilation happens in a short-lived external BEAM that re-enters
  `run_from_env/0`. A broken or hostile compile therefore cannot redefine
  modules in the live VM, and all selected sources are staged before the
  runtime projection is rebuilt. This module mutates no Catalyst registry;
  setup callbacks run only after staged binaries have been accepted and loaded
  by `Catalyst.Extensions.Load`.
  """

  require Logger

  alias Catalyst.{Extension, ExtensionAPI, Tasks}
  alias Catalyst.Extensions.{Contribution, Modules}
  alias Catalyst.Tools.Exec
  alias Catalyst.Tools.Registry, as: ToolRegistry

  @compile_timeout 30_000
  @setup_timeout 30_000
  @stage_output_limit 1_000_000
  @executable_suffix if(:os.type() == {:win32, :nt}, do: ".exe", else: "")

  @typedoc "A compiled file's registry-neutral contribution."
  @type contribution :: Contribution.t()

  @typedoc "One source tagged with its precedence layer."
  @type source_path :: {:bundled | :user, Path.t()}

  @doc "Compile and classify one source file in an isolated BEAM."
  @spec compile(Path.t()) :: {:ok, contribution()} | {:error, term()}
  def compile(path) do
    case compile_many([{:user, path}]) do
      [{:user, ^path, result}] -> result
    end
  end

  @doc "Stage all selected sources in one disposable BEAM, preserving source order."
  @spec compile_many([source_path()]) ::
          [{:bundled | :user, Path.t(), {:ok, contribution()} | {:error, term()}}]
  def compile_many(paths) do
    request_path = scratch_path("request")
    response_path = scratch_path("response")
    request = %{paths: paths, timeout: compile_timeout()}

    try do
      File.write!(request_path, :erlang.term_to_binary(request))
      run_stage(request_path, response_path, length(paths))
      read_stage_response(response_path)
    after
      File.rm(request_path)
      File.rm(response_path)
    end
  end

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

  @doc false
  @spec load(Path.t(), contribution()) :: :ok | {:error, term()}
  def load(path, %Contribution{beams: beams}), do: Modules.load(path, beams)

  @doc false
  @spec prepare_tools(contribution()) :: {:ok, contribution()} | {:error, term()}
  def prepare_tools(%Contribution{} = contribution) do
    with {:ok, entries} <- tool_entries(contribution.tool_mods),
         true <- Map.keys(entries) |> Enum.sort() == Enum.sort(contribution.tool_names) do
      {:ok, %{contribution | tool_entries: entries}}
    else
      false -> {:error, :staged_tool_names_changed}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Run every `setup/1` callback in bounded work and collect cleanly surfaced
  failures. Registrations completed before a failure remain owner-tagged and
  are therefore reversible by the registry.
  """
  @spec run_setups([module()], ExtensionAPI.t()) :: :ok | {:error, term()}
  def run_setups([], _api), do: :ok

  def run_setups(modules, api) do
    task = Tasks.async(fn -> Enum.map(modules, &run_setup(&1, api)) end)

    case Tasks.await(task, setup_timeout()) do
      {:ok, results} -> setup_results(results)
      {:exit, reason} -> setup_exit(api, reason)
      :timeout -> setup_timeout(api)
    end
  end

  defp contribution(compiled, extension_modules, tool_modules, definitions) do
    %Contribution{
      modules: Enum.map(compiled, &elem(&1, 0)),
      beams: Map.new(compiled),
      ext_mods: extension_modules,
      tool_mods: tool_modules,
      tool_names: Enum.map(definitions, & &1.name),
      metadata: Extension.metadata_of(extension_modules)
    }
  end

  defp classify(modules) do
    modules
    |> Enum.reduce({[], []}, &classify_module/2)
    |> then(fn {extensions, tools} -> {Enum.reverse(extensions), Enum.reverse(tools)} end)
  end

  defp classify_module(module, {extensions, tools}) do
    cond do
      Extension.extension_module?(module) -> {[module | extensions], tools}
      tool_module?(module) -> {extensions, [module | tools]}
      true -> {extensions, tools}
    end
  end

  defp tool_definitions(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, definitions} ->
      case ToolRegistry.definition(module) do
        {:ok, definition} -> {:cont, {:ok, [definition | definitions]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_definitions()
  end

  defp reverse_definitions({:ok, definitions}), do: {:ok, Enum.reverse(definitions)}
  defp reverse_definitions({:error, _reason} = error), do: error

  defp tool_entries(modules) do
    Enum.reduce_while(modules, {:ok, %{}}, fn module, {:ok, entries} ->
      case ToolRegistry.entry(module) do
        {:ok, entry} -> {:cont, {:ok, Map.put(entries, entry.definition.name, entry)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp tool_module?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :name, 0) and
      function_exported?(module, :parameters, 0) and
      function_exported?(module, :execute, 2)
  end

  defp run_setup(module, api) do
    normalize_setup_outcome(module, api, setup_outcome(module, api))
  end

  defp setup_outcome(module, api) do
    {:returned, module.setup(api)}
  rescue
    error -> {:raised, error}
  catch
    kind, reason -> {:caught, kind, reason}
  end

  defp normalize_setup_outcome(module, api, {:returned, result}) do
    case result do
      :ok -> :ok
      {:error, reason} -> setup_error(module, api, reason)
      other -> invalid_setup_result(module, api, other)
    end
  end

  defp normalize_setup_outcome(module, api, {:raised, error}),
    do: raised_setup(module, api, error)

  defp normalize_setup_outcome(module, api, {:caught, kind, reason}),
    do: caught_setup(module, api, kind, reason)

  defp setup_error(module, api, reason) do
    Logger.warning(
      "[extensions] #{api.owner}: #{inspect(module)}.setup/1 returned " <>
        "{:error, #{inspect(reason)}}"
    )

    {:error, {module, reason}}
  end

  defp invalid_setup_result(module, api, result) do
    Logger.warning(
      "[extensions] #{api.owner}: #{inspect(module)}.setup/1 returned invalid value: " <>
        inspect(result)
    )

    {:error, {module, {:invalid_return, result}}}
  end

  defp raised_setup(module, api, error) do
    Logger.warning(
      "[extensions] #{api.owner}: #{inspect(module)}.setup/1 raised: " <>
        Exception.message(error)
    )

    {:error, {module, {:exception, Exception.message(error)}}}
  end

  defp caught_setup(module, api, kind, reason) do
    Logger.warning(
      "[extensions] #{api.owner}: #{inspect(module)}.setup/1 #{kind}: #{inspect(reason)}"
    )

    {:error, {module, {kind, reason}}}
  end

  defp setup_results(results) do
    case Enum.filter(results, &match?({:error, _reason}, &1)) do
      [] -> :ok
      errors -> {:error, {:setup_errors, Enum.map(errors, &elem(&1, 1))}}
    end
  end

  defp setup_exit(api, reason) do
    Logger.warning("[extensions] #{api.owner}: setup task exited: #{inspect(reason)}")
    {:error, {:setup_exit, reason}}
  end

  defp setup_timeout(api) do
    timeout = setup_timeout()
    Logger.warning("[extensions] #{api.owner}: setup timed out after #{timeout}ms")
    {:error, :setup_timeout}
  end

  defp compile_timeout do
    Application.get_env(:catalyst, :extension_compile_timeout, @compile_timeout)
  end

  defp setup_timeout do
    Application.get_env(:catalyst, :extension_setup_timeout, @setup_timeout)
  end

  defp run_stage(request_path, response_path, count) do
    {executable, runtime_env, runtime_args} = stage_runtime()

    env = [
      {"CATALYST_EXTENSION_STAGE_REQUEST", request_path},
      {"CATALYST_EXTENSION_STAGE_RESPONSE", response_path}
      | runtime_env
    ]

    args =
      ["+S", "2:2", "+SDio", "1", "+SDcpu", "1", "-noshell", "-noinput"] ++
        runtime_args ++
        code_path_args() ++
        ["-eval", "'Elixir.Catalyst.Extensions.Loader':run_from_env()."]

    timeout = max(count, 1) * compile_timeout() + 5_000

    case Exec.collect(executable, args,
           env: env,
           timeout: timeout,
           max_output_bytes: @stage_output_limit
         ) do
      {:ok, %{status: 0}} ->
        :ok

      {:ok, %{status: status, out: out}} ->
        case File.exists?(response_path) do
          true -> :ok
          false -> raise "stage compiler exited #{status}: #{out}"
        end

      {:error, reason} ->
        raise "stage compiler failed: #{inspect(reason)}"
    end
  end

  defp read_stage_response(path) do
    case path |> File.read!() |> :erlang.binary_to_term() do
      {:stage_crash, reason} -> raise "stage compiler crashed: #{inspect(reason)}"
      results when is_list(results) -> results
    end
  end

  defp code_path_args do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.flat_map(&["-pa", &1])
  end

  @doc false
  @spec stage_executable(Path.t(), String.t()) :: Path.t()
  def stage_executable(root, version) do
    bin_dir = Path.join(root, "erts-#{version}/bin")
    erl = Path.join(bin_dir, executable_name("erl"))
    erlexec = Path.join(bin_dir, executable_name("erlexec"))

    Enum.find([erl, erlexec], &File.regular?/1) || erl
  end

  @doc false
  @spec stage_boot(Path.t()) :: Path.t()
  def stage_boot(root) do
    installed = Path.join(root, "bin/start_clean.boot")
    release = Path.wildcard(Path.join(root, "releases/*/start_clean.boot"))

    [installed | release]
    |> Enum.find(&File.regular?/1)
    |> case do
      nil -> Path.rootname(installed)
      path -> Path.rootname(path)
    end
  end

  defp stage_runtime do
    root = List.to_string(:code.root_dir())
    version = List.to_string(:erlang.system_info(:version))
    executable = stage_executable(root, version)
    bin_dir = Path.dirname(executable)

    {executable,
     [
       {"ROOTDIR", root},
       {"BINDIR", bin_dir},
       {"EMU", "beam"},
       {"PROGNAME", Path.basename(executable)}
     ], ["-boot", stage_boot(root), "-boot_var", "RELEASE_LIB", Path.join(root, "lib")]}
  end

  defp executable_name(name), do: name <> @executable_suffix

  defp scratch_path(kind) do
    id = System.unique_integer([:positive, :monotonic])
    Path.join(System.tmp_dir!(), "catalyst_extension_stage_#{kind}_#{id}")
  end

  defp classify_compiled(compiled) do
    modules = Enum.map(compiled, &elem(&1, 0))
    {extension_modules, tool_modules} = classify(modules)

    with {:ok, definitions} <- tool_definitions(tool_modules) do
      {:ok, contribution(compiled, extension_modules, tool_modules, definitions)}
    end
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
    task = Task.async(fn -> compile_staged_file(path) end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:exit, reason}}
        nil -> {:error, :timeout}
      end

    {source, path, result}
  end

  defp compile_staged_file(path) do
    path
    |> Code.compile_file()
    |> classify_compiled()
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
