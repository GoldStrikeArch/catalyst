defmodule Catalyst.Workflow.Registry do
  @moduledoc """
  Live agent-workflow resolver over the shared runtime contribution store.

  Only runtime registrations live in `Catalyst.Runtime.Registry`. Application configuration and
  persisted templates are read at resolution time, so changes take effect
  without restarting this process. The effective selection order is:

    1. a valid `opts[:loop]` module;
    2. an explicit `opts[:workflow]` name in the runtime overlay, then the live
       `:workflows` application map, then the template store;
    3. the runtime `:default` workflow;
    4. the live `:workflows` default;
    5. the live `:agent_loop` application setting; and
    6. `Catalyst.Agent.Loop`.

  Dynamic workflow families such as configured external agents and durable
  templates are contributed through `Catalyst.Workflow.Source`. The core
  resolver has no knowledge of their storage or execution modules.

  An explicit unknown name is an error and never falls through to the default.
  Reads remain useful while the runtime owner is restarting: a missing table simply
  exposes the current application or built-in layer.
  """

  alias Catalyst.ExtensionAPI
  alias Catalyst.Runtime.Registry, as: Runtime

  @builtin Catalyst.Agent.Loop

  @type name :: String.t() | :default
  @type key :: {:workflow, name()}
  @type source ::
          {:session, :loop}
          | {:runtime, term(), key()}
          | {:application, {:workflows, name()} | :agent_loop}
          | {:source, term(), module()}
          | {:template, map()}
          | :builtin
  @type selection ::
          %{name: name() | :loop, module: module(), source: source()}
          | %{
              name: String.t(),
              module: module(),
              source: source(),
              template: term()
            }
  @type runtime_entry :: %{key: key(), value: module(), owner: term()}

  @doc "Resolve the effective workflow for a run's option collection."
  @spec resolve(keyword() | map()) :: {:ok, selection()} | {:error, term()}
  def resolve(opts \\ []) do
    with {:ok, loop} <- option(opts, :loop),
         {:ok, workflow} <- option(opts, :workflow) do
      resolve_options(loop, workflow)
    end
  end

  # test seam. Resolves one named workflow; :default includes agent-loop and
  # built-in fallbacks.
  @doc false
  @spec fetch(name()) :: {:ok, module()} | {:error, term()}
  def fetch(name) do
    case fetch_with_source(name) do
      {:ok, module, _source} -> {:ok, module}
      {:error, _reason} = error -> error
    end
  end

  # test seam. Resolves one named workflow together with its winning source.
  @doc false
  @spec fetch_with_source(name()) :: {:ok, module(), source()} | {:error, term()}
  def fetch_with_source(:default), do: resolve_default() |> without_template()

  def fetch_with_source(name) do
    case valid_named_workflow?(name) do
      true -> name |> resolve_named() |> without_template()
      false -> {:error, {:invalid_configuration, {:workflow, :name}, name}}
    end
  end

  @doc """
  List every currently selectable workflow with its winning module and source.

  Composes the runtime overlay, the live `:workflows` application map, and the
  default chain into picker-ready `selection()` rows: the effective `:default`
  first, then named workflows in name order. Each row reports the same layer
  `resolve/1` would select for that name right now. Names whose winning layer
  is invalid (a misconfigured module, a malformed `:workflows` value) are
  omitted rather than raised on — explicitly selecting such a name still
  returns its tagged error from `resolve/1`.
  """
  @spec list() :: [selection()]
  def list do
    default_rows() ++ named_rows()
  end

  @doc "Register or refresh a runtime workflow, tagged with an optional owner."
  @spec register_workflow(term(), term(), keyword()) :: :ok | {:error, term()}
  def register_workflow(name, module, opts \\ []) when is_list(opts) do
    key = {:workflow, name}

    with :ok <- validate_registration(key, module) do
      Runtime.put(:workflow, name, module, Keyword.put(opts, :collision_key, name))
    end
  end

  @doc "Drop one runtime overlay, revealing the current lower-precedence layer."
  @spec unregister_workflow(term()) :: :ok
  def unregister_workflow(name), do: Runtime.delete(:workflow, name)

  @doc "Drop every runtime workflow owned by `owner`."
  @spec unregister_owner(term()) :: :ok
  def unregister_owner(owner), do: Runtime.purge_owner(owner, :workflow)

  @doc "Return the owner-aware runtime overlay in stable key order."
  @spec runtime_entries() :: [runtime_entry()]
  def runtime_entries do
    Enum.map(Runtime.list(:workflow), fn entry ->
      %{key: {:workflow, entry.key}, value: entry.value, owner: entry.owner}
    end)
  end

  @doc false
  @spec table() :: atom()
  def table, do: Runtime.table()

  defp default_rows do
    case resolve_default() do
      {:ok, module, source} -> [%{name: :default, module: module, source: source}]
      {:error, _reason} -> []
    end
  end

  defp named_rows do
    (runtime_names() ++ application_names() ++ source_names())
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&named_row/1)
  end

  defp named_row(name) do
    case resolve_named(name) do
      {:ok, module, source} ->
        [%{name: name, module: module, source: source}]

      {:ok, module, source, template} ->
        [%{name: name, module: module, source: source, template: template}]

      {:error, _reason} ->
        []
    end
  end

  defp runtime_names do
    for %{key: name} <- Runtime.list(:workflow), valid_named_workflow?(name), do: name
  end

  defp application_names, do: configured_workflow_names()

  defp configured_workflow_names do
    case Application.fetch_env(:catalyst, :workflows) do
      {:ok, workflows} when is_map(workflows) ->
        for {name, _module} <- workflows, valid_named_workflow?(name), do: name

      _missing_or_malformed ->
        []
    end
  end

  defp source_names do
    Runtime.list(:workflow_source)
    |> Enum.flat_map(fn %{value: module} -> source_list(module) end)
    |> Enum.filter(&valid_named_workflow?/1)
  end

  defp resolve_options({:present, loop}, _workflow) when not is_nil(loop) do
    case valid_workflow_module?(loop) do
      true -> {:ok, %{name: :loop, module: loop, source: {:session, :loop}}}
      false -> {:error, {:invalid_configuration, {:option, :loop}, loop}}
    end
  end

  defp resolve_options(_loop, {:present, :default}) do
    resolve_default()
    |> selection(:default)
  end

  defp resolve_options(_loop, {:present, workflow}) when not is_nil(workflow) do
    case valid_named_workflow?(workflow) do
      true -> workflow |> resolve_named() |> selection(workflow)
      false -> {:error, {:invalid_configuration, {:option, :workflow}, workflow}}
    end
  end

  defp resolve_options(_loop, _workflow) do
    resolve_default()
    |> selection(:default)
  end

  defp selection({:ok, module, source}, name),
    do: {:ok, %{name: name, module: module, source: source}}

  defp selection({:ok, module, source, template}, name),
    do: {:ok, %{name: name, module: module, source: source, template: template}}

  defp selection({:error, _reason} = error, _name), do: error

  defp resolve_named(name) do
    key = {:workflow, name}

    case runtime_lookup(key) do
      {:ok, module, owner} -> {:ok, module, {:runtime, owner, key}}
      :error -> application_workflow(name, :required)
    end
  end

  defp resolve_default do
    key = {:workflow, :default}

    case runtime_lookup(key) do
      {:ok, module, owner} -> {:ok, module, {:runtime, owner, key}}
      :error -> application_workflow(:default, :optional)
    end
  end

  defp application_workflow(name, required?) do
    case Application.fetch_env(:catalyst, :workflows) do
      {:ok, workflows} when is_map(workflows) ->
        selected_application_workflow(workflows, name, required?)

      {:ok, malformed} ->
        {:error, {:invalid_configuration, :workflows, malformed}}

      :error ->
        missing_application_workflow(name, required?)
    end
  end

  defp selected_application_workflow(workflows, name, required?) do
    case Map.fetch(workflows, name) do
      {:ok, module} -> validate_application_module({:workflows, name}, module)
      :error -> missing_application_workflow(name, required?)
    end
  end

  defp missing_application_workflow(name, :required), do: resolve_source(name)

  defp missing_application_workflow(:default, :optional), do: application_agent_loop()

  defp application_agent_loop do
    case Application.fetch_env(:catalyst, :agent_loop) do
      {:ok, module} -> validate_application_module(:agent_loop, module)
      :error -> {:ok, @builtin, :builtin}
    end
  end

  defp validate_application_module(source, module) do
    case valid_workflow_module?(module) do
      true -> {:ok, module, {:application, source}}
      false -> {:error, {:invalid_configuration, source, module}}
    end
  end

  defp option(opts, key) when is_list(opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, {:present, value}}
      :error -> {:ok, :absent}
    end
  end

  defp option(opts, key) when is_map(opts) do
    case Map.fetch(opts, key) do
      {:ok, value} -> {:ok, {:present, value}}
      :error -> {:ok, :absent}
    end
  end

  defp option(opts, _key), do: {:error, {:invalid_configuration, :workflow_options, opts}}

  defp runtime_lookup(key) do
    {:workflow, name} = key

    case Runtime.fetch(:workflow, name) do
      {:ok, module, owner} -> {:ok, module, owner}
      :error -> :error
    end
  end

  defp validate_registration({:workflow, name} = key, module) do
    case valid_name?(name) and valid_workflow_module?(module) do
      true -> :ok
      false -> {:error, {:invalid_registration, key, module}}
    end
  end

  defp valid_name?(:default), do: true
  defp valid_name?(name), do: valid_named_workflow?(name)

  defp valid_named_workflow?(name), do: is_binary(name) and String.trim(name) != ""

  defp resolve_source(name) do
    Runtime.list(:workflow_source)
    |> Enum.reduce_while({:error, {:unknown_workflow, name}}, fn entry, _missing ->
      case source_fetch(entry.value, name) do
        :error -> {:cont, {:error, {:unknown_workflow, name}}}
        {:error, _reason} = error -> {:halt, error}
        {:ok, module} -> {:halt, validate_source_module(module, entry, %{})}
        {:ok, module, metadata} -> {:halt, validate_source_module(module, entry, metadata)}
      end
    end)
  end

  defp validate_source_module(module, entry, metadata) when is_map(metadata) do
    case valid_workflow_module?(module) do
      true ->
        source = Map.get(metadata, :source, {:source, entry.owner, entry.value})

        case Map.fetch(metadata, :template) do
          {:ok, template} -> {:ok, module, source, template}
          :error -> {:ok, module, source}
        end

      false ->
        {:error, {:invalid_workflow_source_module, entry.value, module}}
    end
  end

  defp validate_source_module(_module, entry, metadata),
    do: {:error, {:invalid_workflow_source_metadata, entry.value, metadata}}

  defp source_list(module) do
    case safe_source_call(module, :list, []) do
      names when is_list(names) -> names
      _invalid -> []
    end
  end

  defp source_fetch(module, name), do: safe_source_call(module, :fetch, [name])

  defp safe_source_call(module, function, arguments) do
    case is_atom(module) and Code.ensure_loaded?(module) and
           function_exported?(module, function, length(arguments)) do
      true -> apply(module, function, arguments)
      false -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp without_template({:ok, module, source, _template}), do: {:ok, module, source}
  defp without_template(result), do: result

  defp valid_workflow_module?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :run, 4)
  end

  @doc false
  @spec register_extension_workflow(ExtensionAPI.t(), name(), module(), keyword()) ::
          :ok | {:error, term()}
  def register_extension_workflow(%ExtensionAPI{owner: owner}, name, module, opts) do
    register_workflow(name, module, Keyword.put(opts, :owner, owner))
  end

  @doc false
  @spec register_extension_source(ExtensionAPI.t(), module(), keyword()) ::
          :ok | {:error, term()}
  def register_extension_source(%ExtensionAPI{owner: owner}, module, opts) do
    case valid_source_module?(module) do
      true ->
        Runtime.put(
          :workflow_source,
          module,
          module,
          opts |> Keyword.put(:owner, owner) |> Keyword.put(:collision_key, module)
        )

      false ->
        {:error, {:invalid_workflow_source, module}}
    end
  end

  @doc false
  @spec wire_extension_api() :: :ok
  def wire_extension_api do
    ExtensionAPI.register_kind(:workflow, &__MODULE__.register_extension_workflow/4)
    ExtensionAPI.register_kind(:workflow_source, &__MODULE__.register_extension_source/3)
    :ok
  end

  defp valid_source_module?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :list, 0) and
      function_exported?(module, :fetch, 1)
  end
end
