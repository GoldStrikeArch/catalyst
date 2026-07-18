defmodule Catalyst.Context.Registry do
  @moduledoc """
  Owner-aware runtime overlays for context policies and model thresholds.

  Only runtime registrations live in ETS.  Application configuration is read
  at every resolution, so `Application.put_env/3` and `delete_env/2` remain live
  fallbacks and a registry restart cannot freeze an old value into the table.
  Readers also retain those fallbacks while the named ETS table is absent.
  """

  use GenServer

  alias Catalyst.ExtensionAPI
  alias Catalyst.OwnedIndex

  @table :catalyst_context_registry
  @host_owner :host
  @policy_key {:policy, :default}

  @type model_key :: String.t() | :default
  @type threshold :: :none | pos_integer() | float()
  @type runtime_entry :: %{key: term(), value: term(), owner: term()}

  @doc "Start the singleton registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Register the runtime default context policy."
  @spec register_policy(module(), keyword()) :: :ok | {:error, term()}
  def register_policy(module, opts \\ []),
    do: GenServer.call(__MODULE__, {:register, @policy_key, module, opts})

  @doc "Register a runtime threshold for an exact model id/api or `:default`."
  @spec register_threshold(model_key(), threshold(), keyword()) :: :ok | {:error, term()}
  def register_threshold(model_key, value, opts \\ []),
    do: GenServer.call(__MODULE__, {:register, {:threshold, model_key}, value, opts})

  @doc "Remove one runtime policy overlay."
  @spec unregister_policy() :: :ok
  def unregister_policy, do: GenServer.call(__MODULE__, {:unregister, @policy_key})

  @doc "Remove one runtime threshold overlay."
  @spec unregister_threshold(model_key()) :: :ok
  def unregister_threshold(model_key),
    do: GenServer.call(__MODULE__, {:unregister, {:threshold, model_key}})

  @doc "Remove every runtime registration owned by `owner`."
  @spec unregister_owner(term()) :: :ok
  def unregister_owner(owner), do: GenServer.call(__MODULE__, {:unregister_owner, owner})

  @doc "Owner-aware snapshot of runtime overlays (application values are not included)."
  @spec runtime_entries() :: [runtime_entry()]
  def runtime_entries do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {key, value, owner} -> %{key: key, value: value, owner: owner} end)
    |> Enum.sort_by(&inspect(&1.key))
  rescue
    ArgumentError -> []
  end

  @doc "Resolve the effective context policy (runtime, live app config, built-in)."
  @spec policy() :: {:ok, module(), term()} | {:error, term()}
  def policy do
    case runtime_lookup(@policy_key) do
      {:ok, module, owner} -> {:ok, module, {:extension, owner, @policy_key}}
      :error -> configured_policy()
    end
  end

  @doc "Compatibility projection returning only the effective policy module."
  @spec fetch_policy() :: {:ok, module()} | {:error, term()}
  def fetch_policy do
    case policy() do
      {:ok, module, _source} -> {:ok, module}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Resolve an explicit threshold overlay for a model using exact id, api, then
  `:default`.  Returns `:missing` when the built-in window strategy should run.
  """
  @spec threshold(Catalyst.Model.t() | nil) ::
          {:ok, threshold(), term()} | :missing | {:error, term()}
  def threshold(model) do
    keys = model_keys(model)

    case first_runtime_threshold(keys) do
      {:ok, _value, _source} = found -> found
      :missing -> configured_threshold(keys)
    end
  end

  @doc false
  @spec valid_threshold?(term()) :: boolean()
  def valid_threshold?(:none), do: true
  def valid_threshold?(value) when is_integer(value), do: value > 0
  def valid_threshold?(value) when is_float(value), do: value > 0.0 and value <= 1.0
  def valid_threshold?(_value), do: false

  @doc false
  @spec valid_model_key?(term()) :: boolean()
  def valid_model_key?(:default), do: true
  def valid_model_key?(key) when is_binary(key), do: String.trim(key) != ""
  def valid_model_key?(_key), do: false

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    wire()
    {:ok, OwnedIndex.new()}
  end

  @impl true
  def handle_call({:register, key, value, opts}, _from, state) do
    owner = opts |> Keyword.get(:owner) |> normalize_owner()

    with :ok <- validate_registration(key, value),
         {:ok, state} <- claim(key, owner, state) do
      :ets.insert(@table, {key, value, owner})
      {:reply, :ok, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:unregister, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, OwnedIndex.release(state, key)}
  end

  def handle_call({:unregister_owner, owner}, _from, state) do
    {keys, state} = OwnedIndex.release_owner(state, owner)
    Enum.each(keys, &:ets.delete(@table, &1))
    {:reply, :ok, state}
  end

  defp validate_registration(@policy_key = key, module) do
    case policy_module?(module) do
      true -> :ok
      false -> {:error, {:invalid_registration, key, module}}
    end
  end

  defp validate_registration({:threshold, model_key} = key, value) do
    case valid_model_key?(model_key) and valid_threshold?(value) do
      true -> :ok
      false -> {:error, {:invalid_registration, key, value}}
    end
  end

  defp validate_registration(key, value),
    do: {:error, {:invalid_registration, key, value}}

  defp claim(key, owner, state) do
    case OwnedIndex.claim(state, key, owner) do
      {:ok, state} -> {:ok, state}
      {:error, existing_owner} -> {:error, collision(key, existing_owner, owner)}
    end
  end

  defp collision(@policy_key, existing, attempted),
    do: {:context_policy_owner_collision, existing, attempted}

  defp collision({:threshold, model_key}, existing, attempted),
    do: {:context_threshold_owner_collision, model_key, existing, attempted}

  defp runtime_lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, owner}] -> {:ok, value, owner}
      _missing -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp first_runtime_threshold(keys) do
    Enum.find_value(keys, :missing, fn key ->
      registry_key = {:threshold, key}

      case runtime_lookup(registry_key) do
        {:ok, value, owner} -> {:ok, value, {:extension, owner, registry_key}}
        :error -> false
      end
    end)
  end

  defp configured_policy do
    module = Application.get_env(:catalyst, :context_policy, Catalyst.Context.Window)

    case policy_module?(module) do
      true ->
        source =
          case Application.fetch_env(:catalyst, :context_policy) do
            {:ok, _value} -> {:application, :context_policy}
            :error -> :builtin
          end

        {:ok, module, source}

      false ->
        {:error, {:invalid_configuration, :context_policy, module}}
    end
  end

  defp configured_threshold(keys) do
    case Application.get_env(:catalyst, :context_thresholds, %{}) do
      config when is_map(config) ->
        with :ok <- validate_threshold_config(config) do
          Enum.find_value(keys, :missing, fn key ->
            case Map.fetch(config, key) do
              {:ok, value} -> {:ok, value, {:application, :context_thresholds, key}}
              :error -> false
            end
          end)
        end

      malformed ->
        {:error, {:invalid_configuration, :context_thresholds, malformed}}
    end
  end

  defp validate_threshold_config(config) do
    Enum.reduce_while(config, :ok, fn {key, value}, :ok ->
      case valid_model_key?(key) and valid_threshold?(value) do
        true -> {:cont, :ok}
        false -> {:halt, {:error, {:invalid_configuration, :context_thresholds, {key, value}}}}
      end
    end)
  end

  defp model_keys(nil), do: [:default]

  defp model_keys(model) do
    [Map.get(model, :id), Map.get(model, :api), :default]
    |> Enum.filter(&valid_model_key?/1)
    |> Enum.uniq()
  end

  defp policy_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :threshold, 2) and
      function_exported?(module, :compact, 2)
  end

  defp policy_module?(_module), do: false

  defp normalize_owner(nil), do: @host_owner
  defp normalize_owner(owner), do: owner

  @doc false
  @spec register_extension_policy(ExtensionAPI.t(), module(), keyword()) ::
          :ok | {:error, term()}
  def register_extension_policy(%ExtensionAPI{owner: owner}, module, opts) do
    register_policy(module, Keyword.put(opts, :owner, owner))
  end

  @doc false
  @spec register_extension_threshold(ExtensionAPI.t(), model_key(), threshold(), keyword()) ::
          :ok | {:error, term()}
  def register_extension_threshold(%ExtensionAPI{owner: owner}, model_key, value, opts) do
    register_threshold(model_key, value, Keyword.put(opts, :owner, owner))
  end

  defp wire do
    ExtensionAPI.register_kind(:context_policy, &__MODULE__.register_extension_policy/3)

    ExtensionAPI.register_kind(
      :context_threshold,
      &__MODULE__.register_extension_threshold/4
    )

    ExtensionAPI.register_purger(&__MODULE__.unregister_owner/1)
  end
end
