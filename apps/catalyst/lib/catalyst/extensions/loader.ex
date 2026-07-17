defmodule Catalyst.Extensions.Loader do
  @moduledoc """
  Task-isolated compile, classification, metadata, and setup pipeline for one
  extension source file.

  This module never mutates Catalyst registries. `Catalyst.Extensions` commits
  a successful contribution to ETS and owner tracking, then asks this loader to
  run its setup callbacks. That keeps extension-authored code outside the
  registry GenServer and preserves compile-before-purge semantics.
  """

  require Logger

  alias Catalyst.{Extension, ExtensionAPI, Tasks}
  alias Catalyst.Extensions.CompilerTracer
  alias Catalyst.Tools.Registry, as: ToolRegistry

  @compile_timeout 30_000
  @setup_timeout 30_000

  @typedoc "A compiled file's registry-neutral contribution."
  @type contribution :: %{
          modules: [module()],
          beams: %{module() => binary()},
          ext_mods: [module()],
          tool_mods: [module()],
          tool_names: [String.t()],
          metadata: map()
        }

  @doc "Compile and classify one source file within a bounded task."
  @spec compile(Path.t()) :: {:ok, contribution()} | {:error, term(), [module()]}
  def compile(path) do
    with_compiler_options(fn ->
      collector = self()
      trace_ref = make_ref()
      task = Tasks.async(fn -> compile_and_classify(path, collector, trace_ref) end)
      outcome = Tasks.await(task, compile_timeout())
      emitted_modules = CompilerTracer.collect(trace_ref)

      case outcome do
        {:ok, {:ok, contribution}} -> {:ok, contribution}
        {:ok, {:error, reason}} -> {:error, reason, emitted_modules}
        {:exit, reason} -> {:error, {:exit, reason}, emitted_modules}
        :timeout -> {:error, :timeout, emitted_modules}
      end
    end)
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

  defp compile_and_classify(path, collector, trace_ref) do
    CompilerTracer.start(collector, trace_ref)

    try do
      compiled = compile_extension_file(path)
      modules = Enum.map(compiled, &elem(&1, 0))
      {extension_modules, tool_modules} = classify(modules)

      with {:ok, definitions} <- tool_definitions(tool_modules) do
        {:ok, contribution(compiled, extension_modules, tool_modules, definitions)}
      end
    rescue
      error -> {:error, {:compile, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:compile, {kind, reason}}}
    after
      CompilerTracer.stop()
    end
  end

  defp contribution(compiled, extension_modules, tool_modules, definitions) do
    %{
      modules: Enum.map(compiled, &elem(&1, 0)),
      beams: Map.new(compiled),
      ext_mods: extension_modules,
      tool_mods: tool_modules,
      tool_names: Enum.map(definitions, & &1.name),
      metadata: Extension.metadata_of(extension_modules)
    }
  end

  defp with_compiler_options(fun) do
    previous = Code.compiler_options()

    Code.compiler_options(
      ignore_module_conflict: true,
      tracers: Enum.uniq([CompilerTracer | previous.tracers])
    )

    try do
      fun.()
    after
      Code.compiler_options(previous)
    end
  end

  defp compile_extension_file(path), do: Code.compile_file(path)

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
end
