defmodule Catalyst.LLM.Registry do
  @moduledoc """
  Runtime registry mapping a model's `api` string to its provider. Seeded at boot
  from the built-ins plus `config :catalyst, :llm_providers`, and writable at
  runtime (`register_provider/3`) so an extension can add a new provider — or
  override an existing one — with no restart. Backed by an ETS table like
  `Catalyst.Extensions`; `fetch/1` reads it directly.

  Refactoring an existing provider needs no registry change at all: recompiling
  its module hot-swaps the code, and the next `stream/4` call runs the new
  version. The registry is for *adding/selecting* providers by name.
  """

  use GenServer

  alias Catalyst.ExtensionAPI
  alias Catalyst.LLM.ProviderConfig

  @table :catalyst_llm_providers
  @host_owner :host

  @builtin %{
    "faux" => Catalyst.LLM.Faux,
    "openai-codex-responses" => Catalyst.LLM.OpenAICodex.Provider
  }

  # ---- API ------------------------------------------------------------------

  @doc "Start the (singleton, named) provider registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Resolve the provider MODULE for an api string (stable signature)."
  @spec fetch(String.t()) :: {:ok, module()} | {:error, {:unknown_api, String.t()}}
  def fetch(api) when is_binary(api) do
    case lookup(api) do
      %ProviderConfig{module: module} -> {:ok, module}
      nil -> {:error, {:unknown_api, api}}
    end
  end

  @doc "Like `fetch/1` but raises `ArgumentError` for an unknown api."
  @spec fetch!(String.t()) :: module()
  def fetch!(api) do
    case fetch(api) do
      {:ok, module} ->
        module

      {:error, reason} ->
        raise ArgumentError, "no LLM provider for api #{inspect(api)}: #{inspect(reason)}"
    end
  end

  @doc "The full `%ProviderConfig{}` for an api string, or nil."
  @spec fetch_config(String.t()) :: ProviderConfig.t() | nil
  def fetch_config(api) when is_binary(api), do: lookup(api)

  @doc "All registered providers as `%{api => %ProviderConfig{}}`."
  @spec list() :: %{String.t() => ProviderConfig.t()}
  def list do
    @table |> :ets.tab2list() |> Map.new()
  rescue
    ArgumentError -> seed_map()
  end

  @doc """
  Register (or replace) a provider under `api`. Accepts a `%ProviderConfig{}` or a
  bare provider module. `opts[:owner]` tags it for purge-on-reload.
  """
  @spec register_provider(String.t(), ProviderConfig.t() | module(), keyword()) ::
          :ok | {:error, term()}
  def register_provider(api, config, opts \\ [])

  def register_provider(api, %ProviderConfig{} = config, opts) when is_binary(api),
    do: GenServer.call(__MODULE__, {:register, api, config, opts})

  def register_provider(api, module, opts) when is_binary(api) and is_atom(module),
    do: register_provider(api, %ProviderConfig{module: module}, opts)

  @doc "Remove a provider (restoring a built-in/config one if it was shadowed)."
  @spec unregister_provider(String.t()) :: :ok
  def unregister_provider(api) when is_binary(api),
    do: GenServer.call(__MODULE__, {:unregister, api})

  @doc "Remove every provider registered by `owner` (extension purge hook)."
  @spec unregister_owner(term()) :: :ok
  def unregister_owner(owner), do: GenServer.call(__MODULE__, {:unregister_owner, owner})

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    Enum.each(seed_map(), fn {api, cfg} -> :ets.insert(@table, {api, cfg}) end)
    wire()
    {:ok, %{contrib: %{}, owners: %{}}}
  end

  @impl true
  def handle_call({:register, api, config, opts}, _from, state) do
    owner = normalize_owner(opts[:owner])

    case Map.get(state.owners, api) do
      nil ->
        :ets.insert(@table, {api, config})
        {:reply, :ok, track(api, owner, state)}

      ^owner ->
        :ets.insert(@table, {api, config})
        {:reply, :ok, track(api, owner, state)}

      existing_owner ->
        error = {:provider_owner_collision, api, existing_owner, owner}
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:unregister, api}, _from, state) do
    drop(api)
    {:reply, :ok, detach(api, state)}
  end

  def handle_call({:unregister_owner, owner}, _from, state) do
    apis = Map.get(state.contrib, owner, MapSet.new())

    Enum.each(apis, fn api ->
      case Map.get(state.owners, api) do
        ^owner -> drop(api)
        _other -> :ok
      end
    end)

    owners =
      Map.reject(state.owners, fn {api, api_owner} -> api_owner == owner and api in apis end)

    {:reply, :ok, %{state | contrib: Map.delete(state.contrib, owner), owners: owners}}
  end

  # ---- internals ------------------------------------------------------------

  defp lookup(api) do
    case :ets.lookup(@table, api) do
      [{^api, cfg}] -> cfg
      _ -> Map.get(seed_map(), api)
    end
  rescue
    ArgumentError -> Map.get(seed_map(), api)
  end

  # Drop an entry; if `api` is a built-in/config default, restore that default.
  defp drop(api) do
    :ets.delete(@table, api)

    case Map.get(seed_map(), api) do
      nil -> :ok
      cfg -> :ets.insert(@table, {api, cfg})
    end
  end

  defp track(api, @host_owner, state) do
    state = detach(api, state)
    put_in(state.owners[api], @host_owner)
  end

  defp track(api, owner, state) do
    state = detach(api, state)
    apis = Map.get(state.contrib, owner, MapSet.new())

    state
    |> put_in([:contrib, owner], MapSet.put(apis, api))
    |> put_in([:owners, api], owner)
  end

  defp detach(api, state) do
    contrib =
      Map.new(state.contrib, fn {owner, apis} -> {owner, MapSet.delete(apis, api)} end)

    %{state | contrib: contrib, owners: Map.delete(state.owners, api)}
  end

  defp normalize_owner(nil), do: @host_owner
  defp normalize_owner(owner), do: owner

  defp seed_map do
    builtins =
      Map.new(@builtin, fn {api, mod} -> {api, %ProviderConfig{module: mod, name: api}} end)

    overrides =
      :catalyst
      |> Application.get_env(:llm_providers, %{})
      |> Map.new(fn {api, v} -> {api, normalize(v)} end)

    Map.merge(builtins, overrides)
  end

  defp normalize(%ProviderConfig{} = c), do: c
  defp normalize(module) when is_atom(module), do: %ProviderConfig{module: module}

  defp wire do
    ExtensionAPI.register_kind(:provider, fn api_handle, api, config ->
      register_provider(api, config, owner: api_handle.owner)
    end)

    ExtensionAPI.register_purger(&unregister_owner/1)
  end
end
