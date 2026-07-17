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

  @builtin %{
    "faux" => Catalyst.LLM.Faux,
    "openai-codex-responses" => Catalyst.LLM.OpenAICodex.Provider
  }

  # ---- API ------------------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Resolve the provider MODULE for an api string (stable signature)."
  def fetch(api) when is_binary(api) do
    case lookup(api) do
      %ProviderConfig{module: module} -> {:ok, module}
      nil -> {:error, {:unknown_api, api}}
    end
  end

  def fetch!(api) do
    case fetch(api) do
      {:ok, module} -> module
      {:error, reason} -> raise ArgumentError, "no LLM provider for api #{inspect(api)}: #{inspect(reason)}"
    end
  end

  @doc "The full `%ProviderConfig{}` for an api string, or nil."
  def fetch_config(api) when is_binary(api), do: lookup(api)

  @doc "All registered providers as `%{api => %ProviderConfig{}}`."
  def list do
    @table |> :ets.tab2list() |> Map.new()
  rescue
    ArgumentError -> seed_map()
  end

  @doc """
  Register (or replace) a provider under `api`. Accepts a `%ProviderConfig{}` or a
  bare provider module. `opts[:owner]` tags it for purge-on-reload.
  """
  def register_provider(api, config, opts \\ [])

  def register_provider(api, %ProviderConfig{} = config, opts) when is_binary(api),
    do: GenServer.call(__MODULE__, {:register, api, config, opts})

  def register_provider(api, module, opts) when is_binary(api) and is_atom(module),
    do: register_provider(api, %ProviderConfig{module: module}, opts)

  @doc "Remove a provider (restoring a built-in/config one if it was shadowed)."
  def unregister_provider(api) when is_binary(api), do: GenServer.call(__MODULE__, {:unregister, api})

  @doc "Remove every provider registered by `owner` (extension purge hook)."
  def unregister_owner(owner), do: GenServer.call(__MODULE__, {:unregister_owner, owner})

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    Enum.each(seed_map(), fn {api, cfg} -> :ets.insert(@table, {api, cfg}) end)
    wire()
    {:ok, %{contrib: %{}}}
  end

  @impl true
  def handle_call({:register, api, config, opts}, _from, state) do
    :ets.insert(@table, {api, config})
    {:reply, :ok, track(api, opts[:owner], state)}
  end

  def handle_call({:unregister, api}, _from, state) do
    drop(api)
    {:reply, :ok, state}
  end

  def handle_call({:unregister_owner, owner}, _from, state) do
    state.contrib |> Map.get(owner, MapSet.new()) |> Enum.each(&drop/1)
    {:reply, :ok, %{state | contrib: Map.delete(state.contrib, owner)}}
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

  defp track(_api, nil, state), do: state

  defp track(api, owner, state) do
    apis = Map.get(state.contrib, owner, MapSet.new())
    put_in(state.contrib[owner], MapSet.put(apis, api))
  end

  defp seed_map do
    builtins = Map.new(@builtin, fn {api, mod} -> {api, %ProviderConfig{module: mod, name: api}} end)

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
