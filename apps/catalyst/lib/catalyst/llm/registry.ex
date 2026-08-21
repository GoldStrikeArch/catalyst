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
  alias Catalyst.Extensions.Owner
  alias Catalyst.LLM.ProviderConfig
  alias Catalyst.OwnedIndex

  @table :catalyst_llm_providers

  @builtin %{
    "faux" => Catalyst.LLM.Faux,
    "openai-codex-responses" => Catalyst.LLM.OpenAICodex.Provider,
    "grok-subscription-chat-completions" => Catalyst.LLM.GrokSubscription.Provider
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

  @doc "The full `%ProviderConfig{}` for an api string. Returns `{:ok, config}` or `:error`."
  @spec fetch_config(String.t()) :: {:ok, ProviderConfig.t()} | :error
  def fetch_config(api) when is_binary(api) do
    case lookup(api) do
      %ProviderConfig{} = config -> {:ok, config}
      nil -> :error
    end
  end

  @doc "All registered providers as `%{api => %ProviderConfig{}}`."
  @spec list() :: %{String.t() => ProviderConfig.t()}
  def list do
    case table_rows() do
      {:ok, rows} -> Map.new(rows)
      :error -> seed_map()
    end
  end

  @doc "Runtime owner claims by provider API; seed-only providers are omitted."
  @spec runtime_owners() :: %{optional(String.t()) => term()}
  def runtime_owners do
    case Process.whereis(__MODULE__) do
      nil -> %{}
      _pid -> GenServer.call(__MODULE__, :runtime_owners)
    end
  catch
    :exit, _reason -> %{}
  end

  # The rescue wraps only the :ets call: a missing table (registry restarting)
  # falls back to the seed layer; a malformed row is a real bug and must crash.
  defp table_rows do
    {:ok, :ets.tab2list(@table)}
  rescue
    ArgumentError -> :error
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
    {:ok, OwnedIndex.new()}
  end

  @impl true
  def handle_call(:runtime_owners, _from, state),
    do: {:reply, state.by_key, state}

  def handle_call({:register, api, config, opts}, _from, state) do
    owner = Owner.normalize(opts[:owner])

    case validate_provider_module(config.module) do
      :ok ->
        case OwnedIndex.claim(state, api, owner, track_owner: owner != Owner.host()) do
          {:ok, state} ->
            :ets.insert(@table, {api, config})
            {:reply, :ok, state}

          {:error, existing_owner} ->
            error = {:owner_collision, :provider, api, existing_owner, owner}
            {:reply, {:error, error}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister, api}, _from, state) do
    drop(api)
    {:reply, :ok, OwnedIndex.release(state, api)}
  end

  def handle_call({:unregister_owner, owner}, _from, state) do
    {apis, state} = OwnedIndex.release_owner(state, owner)
    Enum.each(apis, &drop/1)
    {:reply, :ok, state}
  end

  defp validate_provider_module(module) do
    cond do
      not is_atom(module) ->
        {:error, :invalid_provider_module}

      not Code.ensure_loaded?(module) ->
        {:error, {:module_not_found, module}}

      not function_exported?(module, :stream, 4) ->
        {:error, {:missing_stream_4, module}}

      true ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ---- internals ------------------------------------------------------------

  defp lookup(api) do
    case lookup_row(api) do
      [{^api, cfg}] -> cfg
      _ -> Map.get(seed_map(), api)
    end
  end

  defp lookup_row(api) do
    :ets.lookup(@table, api)
  rescue
    ArgumentError -> []
  end

  # Drop an entry; if `api` is a built-in/config default, restore that default.
  defp drop(api) do
    :ets.delete(@table, api)

    case Map.get(seed_map(), api) do
      nil -> :ok
      cfg -> :ets.insert(@table, {api, cfg})
    end
  end

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

  @doc false
  @spec register_extension_provider(ExtensionAPI.t(), String.t(), ProviderConfig.t() | module()) ::
          :ok | {:error, term()}
  def register_extension_provider(%ExtensionAPI{owner: owner}, api, config) do
    register_provider(api, config, owner: owner)
  end

  @doc false
  @spec activate_provider_claim(ExtensionAPI.t(), Catalyst.Runtime.Claim.t(), keyword()) ::
          :ok | {:error, term()}
  def activate_provider_claim(
        api,
        %Catalyst.Runtime.Claim{
          key: %Catalyst.Runtime.ServiceKey{slot: name},
          implementation: config,
          scope: %Catalyst.Runtime.Scope{constraints: constraints},
          priority: 800,
          binding: {:pin, :request}
        },
        _opts
      )
      when map_size(constraints) == 0,
      do: register_extension_provider(api, name, config)

  def activate_provider_claim(_api, claim, _opts),
    do: {:error, {:unsupported_provider_claim, claim}}

  defp wire do
    :ok =
      ExtensionAPI.register_extension_point(
        %{
          id: "llm.provider",
          cardinality: :many,
          contract: Catalyst.Runtime.ContractRef.new!("catalyst.llm-provider", 1),
          service: {"llm", "provider"},
          default_binding: {:pin, :request}
        },
        {__MODULE__, :activate_provider_claim}
      )

    ExtensionAPI.register_purger(&__MODULE__.unregister_owner/1)
  end
end
