defmodule Catalyst.Workflow.Registry do
  @moduledoc """
  Owned runtime overlay and live resolver for agent workflows.

  Only runtime registrations live in ETS. Application configuration and
  persisted templates are read at resolution time, so changes take effect
  without restarting this process. The effective selection order is:

    1. a valid `opts[:loop]` module;
    2. an explicit `opts[:workflow]` name in the runtime overlay, then the live
       `:workflows` application map, then the template store;
    3. the runtime `:default` workflow;
    4. the live `:workflows` default;
    5. the live `:agent_loop` application setting; and
    6. `Catalyst.Agent.Loop`.

  The template store module is configured as `:workflow_template_store` and
  defaults to `Catalyst.Workflow.Template.Store`. It must expose `list/0` and
  `fetch/1`, returning `{:ok, [template]}` and
  `{:ok, template} | :error | {:error, reason}` respectively. Validated
  templates must be maps with a non-empty binary `:name`. A selected template
  is pinned in the selection map and runs through `Catalyst.Workflow.Runner`.

  An explicit unknown name is an error and never falls through to the default.
  Reads remain useful while the ETS owner is restarting: a missing table simply
  exposes the current application or built-in layer.
  """

  use GenServer

  alias Catalyst.ExtensionAPI
  alias Catalyst.Extensions.Owner

  @table :catalyst_workflows
  @builtin Catalyst.Agent.Loop
  @template_runner Catalyst.Workflow.Runner

  @type name :: String.t() | :default
  @type key :: {:workflow, name()}
  @type template :: %{required(:name) => String.t(), optional(atom()) => term()}
  @type source ::
          {:session, :loop}
          | {:runtime, term(), key()}
          | {:application, {:workflows, name()} | :agent_loop}
          | {:template, map()}
          | :builtin
  @type selection ::
          %{name: name() | :loop, module: module(), source: source()}
          | %{
              name: String.t(),
              module: module(),
              source: source(),
              template: template()
            }
  @type runtime_entry :: %{key: key(), value: module(), owner: term()}

  @doc "Start the singleton workflow registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

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
    GenServer.call(__MODULE__, {:register, name, module, opts})
  end

  @doc "Drop one runtime overlay, revealing the current lower-precedence layer."
  @spec unregister_workflow(term()) :: :ok
  def unregister_workflow(name), do: GenServer.call(__MODULE__, {:unregister, name})

  @doc "Drop every runtime workflow owned by `owner`."
  @spec unregister_owner(term()) :: :ok
  def unregister_owner(owner), do: GenServer.call(__MODULE__, {:unregister_owner, owner})

  @doc "Return the owner-aware runtime overlay in stable key order."
  @spec runtime_entries() :: [runtime_entry()]
  def runtime_entries do
    case table_rows() do
      {:ok, rows} ->
        rows
        |> Enum.map(fn {key, value, owner} -> %{key: key, value: value, owner: owner} end)
        |> Enum.sort_by(&inspect(&1.key))

      :error ->
        []
    end
  end

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    wire_extension_api()
    {:ok, :ok}
  end

  @impl true
  def handle_call({:register, name, module, opts}, _from, state) do
    key = {:workflow, name}

    case validate_registration(key, module) do
      :ok -> register(key, module, Owner.normalize(opts[:owner]), state)
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:unregister, name}, _from, state) do
    :ets.delete(@table, {:workflow, name})
    {:reply, :ok, state}
  end

  def handle_call({:unregister_owner, owner}, _from, state) do
    :ets.match_delete(@table, {:_, :_, owner})
    {:reply, :ok, state}
  end

  defp default_rows do
    case resolve_default() do
      {:ok, module, source} -> [%{name: :default, module: module, source: source}]
      {:error, _reason} -> []
    end
  end

  defp named_rows do
    (runtime_names() ++ application_names() ++ template_names())
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
    case table_rows() do
      {:ok, rows} ->
        for {{:workflow, name}, _module, _owner} <- rows, valid_named_workflow?(name), do: name

      :error ->
        []
    end
  end

  defp application_names do
    case Application.fetch_env(:catalyst, :workflows) do
      {:ok, workflows} when is_map(workflows) ->
        for {name, _module} <- workflows, valid_named_workflow?(name), do: name

      _missing_or_malformed ->
        []
    end
  end

  defp template_names do
    case template_store_call(:list, []) do
      {:ok, templates} when is_list(templates) ->
        for template <- templates,
            {:ok, name} <- [template_name(template)],
            do: name

      _missing_or_invalid ->
        []
    end
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

  defp missing_application_workflow(name, :required), do: resolve_template(name)

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
    case lookup_row(key) do
      [{^key, module, owner}] -> {:ok, module, owner}
      _missing -> :error
    end
  end

  # The rescues wrap only the :ets call: reads keep exposing the application
  # and built-in layers while the owner table is absent; malformed rows must
  # not read as "no overlays".
  defp lookup_row(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  defp table_rows do
    {:ok, :ets.tab2list(@table)}
  rescue
    ArgumentError -> :error
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

  defp resolve_template(name) do
    case template_store_call(:fetch, [name]) do
      {:ok, template} -> validate_template(name, template)
      :error -> {:error, {:unknown_workflow, name}}
      {:error, :not_found} -> {:error, {:unknown_workflow, name}}
      {:error, reason} -> {:error, {:workflow_template_store, reason}}
      other -> {:error, {:invalid_workflow_template_store_response, :fetch, other}}
    end
  end

  defp validate_template(name, template) do
    case template_name(template) do
      {:ok, ^name} -> {:ok, @template_runner, {:template, template_metadata(template)}, template}
      {:ok, other} -> {:error, {:workflow_template_name_mismatch, name, other}}
      :error -> {:error, {:invalid_workflow_template, name, template}}
    end
  end

  defp template_name(template) when is_map(template) do
    case Map.get(template, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> :error
          _non_empty -> {:ok, name}
        end

      _invalid ->
        :error
    end
  end

  defp template_name(_template), do: :error

  defp template_metadata(template) do
    Map.take(template, [:name, :id, :version, :revision, :digest])
  end

  defp template_store_call(function, arguments) do
    store =
      Application.get_env(
        :catalyst,
        :workflow_template_store,
        Catalyst.Workflow.Template.Store
      )

    case is_atom(store) and Code.ensure_loaded?(store) and
           function_exported?(store, function, length(arguments)) do
      true -> apply(store, function, arguments)
      false -> :error
    end
  end

  defp without_template({:ok, module, source, _template}), do: {:ok, module, source}
  defp without_template(result), do: result

  defp valid_workflow_module?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :run, 4)
  end

  # Ownership lives in ETS column 3 (single writer: this process), so a claim
  # is a plain lookup — no second bookkeeping structure to desync.
  defp register(key, module, owner, state) do
    case runtime_lookup(key) do
      :error -> put_registration(key, module, owner, state)
      {:ok, _module, ^owner} -> put_registration(key, module, owner, state)
      {:ok, _module, existing} -> collision(key, existing, owner, state)
    end
  end

  defp put_registration(key, module, owner, state) do
    :ets.insert(@table, {key, module, owner})
    {:reply, :ok, state}
  end

  defp collision({:workflow, name}, existing_owner, attempted_owner, state) do
    error = {:owner_collision, :workflow, name, existing_owner, attempted_owner}
    {:reply, {:error, error}, state}
  end

  @doc false
  @spec register_extension_workflow(ExtensionAPI.t(), name(), module(), keyword()) ::
          :ok | {:error, term()}
  def register_extension_workflow(%ExtensionAPI{owner: owner}, name, module, opts) do
    register_workflow(name, module, Keyword.put(opts, :owner, owner))
  end

  defp wire_extension_api do
    ExtensionAPI.register_kind(:workflow, &__MODULE__.register_extension_workflow/4)
    ExtensionAPI.register_purger(&__MODULE__.unregister_owner/1)
  end
end
