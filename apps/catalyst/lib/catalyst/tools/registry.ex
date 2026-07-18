defmodule Catalyst.Tools.Registry do
  @moduledoc """
  The set of built-in tools, plus validated metadata used to look tools up and
  advertise them to providers.

  Metadata callbacks are extension code, so they are evaluated under a bounded
  task when a tool is registered and cached with the module's BEAM fingerprint.
  Turn assembly reads that cache. A hot reload changes the fingerprint and
  triggers one fresh validation before the new code is advertised.
  """

  use GenServer
  require Logger

  alias Catalyst.Tasks

  alias Catalyst.Tools.{
    Read,
    Write,
    Edit,
    Ls,
    Bash,
    Ripgrep,
    Fd,
    Sd,
    AstGrep,
    DevelopTool,
    InstallExtension,
    ReloadTool,
    RollbackTool,
    ReadLog,
    ListAgents,
    SpawnAgent
  }

  @default [
    Read,
    Ls,
    Ripgrep,
    Fd,
    Bash,
    Write,
    Edit,
    Sd,
    AstGrep,
    DevelopTool,
    InstallExtension,
    ReloadTool,
    RollbackTool,
    ReadLog,
    ListAgents,
    SpawnAgent
  ]

  @metadata_timeout 1_000
  @cache_prefix {__MODULE__, :definition}

  @typedoc "Validated metadata used to register a tool and advertise it to a provider."
  @type definition :: %{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          execution_mode: :parallel | :sequential
        }

  @typedoc "A fingerprinted tool definition, execution target, and pre-resolved schema."
  @type entry :: %{
          module: module(),
          fingerprint: binary(),
          definition: definition(),
          resolved_schema: {:ok, term()} | :error,
          executor: (map(), map() -> term()) | :external
        }

  @typedoc "Tool name => validated entry lookup map, as built by `index/1`."
  @type index :: %{optional(String.t()) => entry()}

  @doc "Start the registry and validate/cache the built-in tool definitions."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The default tool module list."
  @spec default_tools() :: [module()]
  def default_tools, do: @default

  @doc """
  Map of tool name => validated entry for the given tool list.

  Build this once per batch and pass it to `fetch/2` to avoid re-deriving the
  map (and calling each tool's `name/0`) on every lookup.
  """
  @spec index([module()]) :: index()
  def index(tools \\ @default) do
    Enum.reduce(tools, %{}, fn module, index ->
      case cached_entry(module) do
        {:ok, entry} -> Map.put(index, entry.definition.name, entry)
        {:error, reason} -> log_unavailable(module, reason, index)
      end
    end)
  end

  @doc """
  Look up a tool module by its name.

  Accepts either a tool module list or a prebuilt `index/1` map and returns
  `{:ok, module}`, or `:error` when no tool has that name.
  """
  @spec fetch([module()] | index(), String.t()) :: {:ok, module()} | :error
  def fetch(tools, name) when is_list(tools) do
    case fetch_entry(tools, name) do
      {:ok, entry} -> {:ok, entry.module}
      :error -> :error
    end
  end

  def fetch(index, name) when is_map(index) do
    case Map.fetch(index, name) do
      {:ok, %{module: module}} -> {:ok, module}
      # Accept old/prebuilt name => module maps for public API compatibility.
      {:ok, module} when is_atom(module) -> {:ok, module}
      :error -> :error
    end
  end

  @doc "Look up the complete validated tool entry by name."
  @spec fetch_entry([module()] | index(), String.t()) :: {:ok, entry()} | :error
  def fetch_entry(tools, name) when is_list(tools), do: tools |> index() |> Map.fetch(name)

  def fetch_entry(index, name) when is_map(index) do
    case Map.fetch(index, name) do
      {:ok,
       %{
         module: _module,
         fingerprint: _fingerprint,
         definition: _definition,
         resolved_schema: _schema,
         executor: _executor
       } = entry} ->
        {:ok, entry}

      {:ok, %{module: module}} when is_atom(module) ->
        fetch_legacy_entry(module)

      {:ok, module} when is_atom(module) ->
        fetch_legacy_entry(module)

      :error ->
        :error
    end
  end

  @doc "Whether an entry still names the BEAM generation that supplied its metadata."
  @spec entry_current?(entry()) :: boolean()
  def entry_current?(%{module: module, fingerprint: expected}) do
    case loaded_fingerprint(module) do
      {:ok, ^expected} -> true
      _changed_or_unloaded -> false
    end
  end

  @doc "Return the generation-safe execution target for a validated entry."
  @spec execution_target(entry()) ::
          {:ok, (map(), map() -> term())} | {:error, {:stale_tool_entry, module()}}
  def execution_target(%{executor: executor}) when is_function(executor, 2),
    do: {:ok, executor}

  def execution_target(%{executor: :external, module: module} = entry) do
    case entry_current?(entry) do
      true -> {:ok, Function.capture(module, :execute, 2)}
      false -> {:error, {:stale_tool_entry, module}}
    end
  end

  @doc "Validate that every called tool has a generation-safe execution target."
  @spec validate_index(index(), [String.t()]) ::
          :ok | {:error, {:stale_tool_entry, String.t(), module()}}
  def validate_index(index, names) when is_map(index) and is_list(names) do
    names
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn name, :ok -> validate_index_entry(index, name) end)
  end

  defp fetch_legacy_entry(module) do
    case cached_entry(module) do
      {:ok, entry} -> {:ok, entry}
      {:error, _reason} -> :error
    end
  end

  @doc """
  Resolve and validate all registration metadata in bounded, isolated work.

  Extension-authored callbacks never execute in a registry GenServer. A
  raising, exiting, malformed, hanging, or concurrently replaced callback
  returns a tagged error. Successful metadata is cached for turn assembly.
  """
  @spec definition(module(), keyword()) :: {:ok, definition()} | {:error, term()}
  def definition(module, opts \\ []) when is_atom(module) do
    case resolve_and_cache(module, opts) do
      {:ok, entry} -> {:ok, entry.definition}
      {:error, _reason} = error -> error
    end
  end

  @doc "Resolve and validate a module into the complete cached tool entry."
  @spec entry(module(), keyword()) :: {:ok, entry()} | {:error, term()}
  def entry(module, opts \\ []) when is_atom(module), do: resolve_and_cache(module, opts)

  defp resolve_and_cache(module, opts) do
    with {:ok, before_fingerprint} <- fingerprint(module),
         result <- await_entry(module, opts),
         {:ok, ^before_fingerprint} <- fingerprint(module) do
      result = attach_fingerprint(result, before_fingerprint)
      cache_result(module, before_fingerprint, result)
    else
      {:ok, _changed_fingerprint} -> {:error, {:tool_metadata_changed, module}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Read metadata previously validated by `definition/2`.

  A missing or stale entry is validated once as a safe fallback for direct
  session tools and focused scripts. Both successful definitions and validation
  failures are cached by BEAM fingerprint, so later turns never repeat the
  extension callbacks unless the module code changes or `invalidate/1` is used.
  """
  @spec cached_definition(module()) :: {:ok, definition()} | {:error, term()}
  def cached_definition(module) when is_atom(module) do
    case cached_entry(module) do
      {:ok, entry} -> {:ok, entry.definition}
      {:error, _reason} = error -> error
    end
  end

  @doc "Read the complete validated entry, refreshing it once when missing or stale."
  @spec cached_entry(module()) :: {:ok, entry()} | {:error, term()}
  def cached_entry(module) when is_atom(module) do
    case fetch_cached(module) do
      {:cached,
       {:ok,
        %{
          module: _module,
          fingerprint: _fingerprint,
          definition: _definition,
          resolved_schema: _schema,
          executor: _executor
        }} = result} ->
        result

      {:cached, {:error, _reason} = error} ->
        error

      # Upgrade the definition-only cache shape used before entries also owned
      # execution validation. This matters when Catalyst hot-reloads itself.
      {:cached, _legacy_result} ->
        entry(module)

      {:uncached, _reason} ->
        entry(module)
    end
  end

  @doc "Remove cached metadata for `module`; the next registration must validate it again."
  @spec invalidate(module()) :: :ok
  def invalidate(module) when is_atom(module) do
    :persistent_term.erase(cache_key(module))
    :ok
  end

  @doc "Serialize tools to the provider shape: `[%{name, description, parameters}]`."
  @spec to_provider_tools([module()] | index()) :: [
          %{name: String.t(), description: String.t(), parameters: map()}
        ]
  def to_provider_tools(tools \\ @default)

  def to_provider_tools(tools) when is_list(tools) do
    Enum.flat_map(tools, fn module ->
      case cached_entry(module) do
        {:ok, entry} ->
          [provider_definition(entry)]

        {:error, reason} ->
          log_unavailable(module, reason, nil)
          []
      end
    end)
  end

  def to_provider_tools(index) when is_map(index) do
    index
    |> Map.values()
    |> Enum.flat_map(fn
      %{definition: _definition} = entry -> [provider_definition(entry)]
      _invalid -> []
    end)
    |> Enum.sort_by(& &1.name)
  end

  @impl true
  def init(_opts) do
    case validate_defaults(@default) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp resolve_entry(module) do
    with :ok <- ensure_tool(module),
         {:ok, name} <- callback(module, :name, &is_binary/1, :bad_tool_name),
         {:ok, description} <-
           callback(module, :description, &is_binary/1, :bad_tool_description),
         {:ok, parameters} <- callback(module, :parameters, &is_map/1, :bad_tool_parameters),
         {:ok, execution_mode} <- execution_mode(module),
         {:ok, executor} <- executor(module) do
      definition = %{
        name: name,
        description: description,
        parameters: parameters,
        execution_mode: execution_mode
      }

      {:ok,
       %{
         module: module,
         definition: definition,
         resolved_schema: resolve_schema(parameters),
         executor: executor
       }}
    end
  end

  defp await_entry(module, opts) do
    task = Tasks.async(fn -> resolve_entry(module) end)

    case Tasks.await(task, Keyword.get(opts, :timeout, metadata_timeout())) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:tool_metadata_exit, module, reason}}
      :timeout -> {:error, {:tool_metadata_timeout, module}}
    end
  end

  defp validate_defaults(modules) do
    Enum.reduce_while(modules, :ok, fn module, :ok ->
      case entry(module) do
        {:ok, _entry} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_builtin_tool, module, reason}}}
      end
    end)
  end

  defp cache_result(module, fingerprint, result) do
    :persistent_term.put(cache_key(module), {fingerprint, result})
    result
  end

  defp fetch_cached(module) do
    with {:ok, fingerprint} <- fingerprint(module),
         {^fingerprint, result} <- :persistent_term.get(cache_key(module), :missing) do
      {:cached, result}
    else
      :missing -> {:uncached, {:tool_metadata_not_registered, module}}
      {:error, reason} -> {:uncached, reason}
      {_old_fingerprint, _result} -> {:uncached, {:stale_tool_metadata, module}}
    end
  end

  defp fingerprint(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> {:ok, module.module_info(:md5)}
      {:error, reason} -> {:error, {:not_a_tool, module, reason}}
    end
  rescue
    error -> {:error, {:not_a_tool, module, Exception.message(error)}}
  end

  defp cache_key(module), do: {@cache_prefix, module}

  defp log_unavailable(module, reason, return_value) do
    Logger.warning(
      "[tools] #{inspect(module)} metadata unavailable; tool omitted: #{inspect(reason)}"
    )

    return_value
  end

  defp ensure_tool(module) do
    callbacks = [name: 0, description: 0, parameters: 0, execute: 2]

    case Code.ensure_loaded?(module) and
           Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end) do
      true -> :ok
      false -> {:error, {:not_a_tool, module}}
    end
  end

  defp callback(module, callback, valid?, error_tag) do
    value = apply(module, callback, [])

    case valid?.(value) do
      true -> {:ok, value}
      false -> {:error, {error_tag, value}}
    end
  rescue
    error -> {:error, {error_tag, Exception.message(error)}}
  catch
    kind, reason -> {:error, {error_tag, {kind, reason}}}
  end

  defp execution_mode(module) do
    case function_exported?(module, :execution_mode, 0) do
      true -> callback(module, :execution_mode, &(&1 in [:parallel, :sequential]), :bad_tool_mode)
      false -> {:ok, :parallel}
    end
  end

  defp executor(module) do
    case function_exported?(module, :__catalyst_executor__, 0) do
      true -> callback(module, :__catalyst_executor__, &is_function(&1, 2), :bad_tool_executor)
      false -> {:ok, :external}
    end
  end

  defp validate_index_entry(index, name) do
    case fetch_entry(index, name) do
      {:ok, entry} ->
        case execution_target(entry) do
          {:ok, _executor} ->
            {:cont, :ok}

          {:error, {:stale_tool_entry, module}} ->
            {:halt, {:error, {:stale_tool_entry, name, module}}}
        end

      :error ->
        # Unknown tools retain their ordinary per-call error result.
        {:cont, :ok}
    end
  end

  defp attach_fingerprint({:ok, entry}, fingerprint),
    do: {:ok, Map.put(entry, :fingerprint, fingerprint)}

  defp attach_fingerprint({:error, _reason} = error, _fingerprint), do: error

  defp loaded_fingerprint(module) do
    case :code.is_loaded(module) do
      false -> {:error, :not_loaded}
      {_kind, _path} -> {:ok, module.module_info(:md5)}
    end
  rescue
    _error -> {:error, :not_loaded}
  catch
    _kind, _reason -> {:error, :not_loaded}
  end

  # A malformed or externally-referencing schema does not make the tool
  # unavailable. It preserves the existing permissive behavior by recording
  # `:error`, which tells ToolRunner to skip argument validation.
  defp provider_definition(entry),
    do: Map.take(entry.definition, [:name, :description, :parameters])

  defp resolve_schema(parameters) do
    schema =
      parameters
      |> Jason.encode!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    {:ok, schema}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp metadata_timeout do
    Application.get_env(:catalyst, :tool_metadata_timeout, @metadata_timeout)
  end
end
