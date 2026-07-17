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
    ReadLog
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
    ReadLog
  ]

  @metadata_timeout 1_000
  @cache_prefix {__MODULE__, :definition}

  @typedoc "Tool name => module lookup map, as built by `index/1`."
  @type index :: %{optional(String.t()) => module()}

  @typedoc "Validated metadata used to register a tool and advertise it to a provider."
  @type definition :: %{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          execution_mode: :parallel | :sequential
        }

  @doc "Start the registry and validate/cache the built-in tool definitions."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The default tool module list."
  @spec default_tools() :: [module()]
  def default_tools, do: @default

  @doc """
  Map of tool name => module for the given tool list.

  Build this once per batch and pass it to `fetch/2` to avoid re-deriving the
  map (and calling each tool's `name/0`) on every lookup.
  """
  @spec index([module()]) :: index()
  def index(tools \\ @default) do
    Enum.reduce(tools, %{}, fn module, index ->
      case cached_definition(module) do
        {:ok, definition} -> Map.put(index, definition.name, module)
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
  def fetch(tools, name) when is_list(tools), do: tools |> index() |> Map.fetch(name)
  def fetch(index, name) when is_map(index), do: Map.fetch(index, name)

  @doc """
  Resolve and validate all registration metadata in bounded, isolated work.

  Extension-authored callbacks never execute in a registry GenServer. A
  raising, exiting, malformed, hanging, or concurrently replaced callback
  returns a tagged error. Successful metadata is cached for turn assembly.
  """
  @spec definition(module(), keyword()) :: {:ok, definition()} | {:error, term()}
  def definition(module, opts \\ []) when is_atom(module) do
    with {:ok, before_fingerprint} <- fingerprint(module),
         result <- await_definition(module, opts),
         {:ok, ^before_fingerprint} <- fingerprint(module) do
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
    case fetch_cached(module) do
      {:cached, result} ->
        result

      {:uncached, _reason} ->
        definition(module)
    end
  end

  @doc "Remove cached metadata for `module`; the next registration must validate it again."
  @spec invalidate(module()) :: :ok
  def invalidate(module) when is_atom(module) do
    :persistent_term.erase(cache_key(module))
    :ok
  end

  @doc "Serialize tools to the provider shape: `[%{name, description, parameters}]`."
  @spec to_provider_tools([module()]) :: [
          %{name: String.t(), description: String.t(), parameters: map()}
        ]
  def to_provider_tools(tools \\ @default) do
    Enum.flat_map(tools, fn module ->
      case cached_definition(module) do
        {:ok, definition} ->
          [Map.take(definition, [:name, :description, :parameters])]

        {:error, reason} ->
          log_unavailable(module, reason, nil)
          []
      end
    end)
  end

  @impl true
  def init(_opts) do
    case validate_defaults(@default) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp resolve_definition(module) do
    with :ok <- ensure_tool(module),
         {:ok, name} <- callback(module, :name, &is_binary/1, :bad_tool_name),
         {:ok, description} <-
           callback(module, :description, &is_binary/1, :bad_tool_description),
         {:ok, parameters} <- callback(module, :parameters, &is_map/1, :bad_tool_parameters),
         {:ok, execution_mode} <- execution_mode(module) do
      {:ok,
       %{
         name: name,
         description: description,
         parameters: parameters,
         execution_mode: execution_mode
       }}
    end
  end

  defp await_definition(module, opts) do
    task = Tasks.async(fn -> resolve_definition(module) end)

    case Tasks.await(task, Keyword.get(opts, :timeout, metadata_timeout())) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:tool_metadata_exit, module, reason}}
      :timeout -> {:error, {:tool_metadata_timeout, module}}
    end
  end

  defp validate_defaults(modules) do
    Enum.reduce_while(modules, :ok, fn module, :ok ->
      case definition(module) do
        {:ok, _definition} -> {:cont, :ok}
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

  defp metadata_timeout do
    Application.get_env(:catalyst, :tool_metadata_timeout, @metadata_timeout)
  end
end
