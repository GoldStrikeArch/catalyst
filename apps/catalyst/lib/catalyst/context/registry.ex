defmodule Catalyst.Context.Registry do
  @moduledoc """
  Context resolution and registration over the shared runtime contribution store.

  Only runtime registrations live in `Catalyst.Runtime.Registry`. Application configuration is read
  at every resolution, so `Application.put_env/3` and `delete_env/2` remain live
  fallbacks and a runtime restart cannot freeze an old value into the table.
  """

  alias Catalyst.ExtensionAPI
  alias Catalyst.Runtime.Registry, as: Runtime

  @policy_key {:policy, :default}

  @type model_key :: String.t() | :default
  @type threshold :: :none | pos_integer() | float()

  @doc "Register the runtime default context policy."
  @spec register_policy(module(), keyword()) :: :ok | {:error, term()}
  def register_policy(module, opts \\ []) do
    with :ok <- validate_registration(@policy_key, module) do
      Runtime.put(:context_policy, :default, module, Keyword.put(opts, :collision_key, nil))
    end
  end

  @doc "Register a runtime threshold for an exact model id/api or `:default`."
  @spec register_threshold(model_key(), threshold(), keyword()) :: :ok | {:error, term()}
  def register_threshold(model_key, value, opts \\ []) do
    key = {:threshold, model_key}

    with :ok <- validate_registration(key, value) do
      Runtime.put(:context_threshold, model_key, value, opts)
    end
  end

  @doc "Remove one runtime policy overlay."
  @spec unregister_policy() :: :ok
  def unregister_policy, do: Runtime.delete(:context_policy, :default)

  @doc "Remove one runtime threshold overlay."
  @spec unregister_threshold(model_key()) :: :ok
  def unregister_threshold(model_key), do: Runtime.delete(:context_threshold, model_key)

  @doc "Resolve the effective context policy (runtime, live app config, built-in)."
  @spec policy() :: {:ok, module(), term()} | {:error, term()}
  def policy do
    case runtime_policy() do
      {:ok, module, owner} -> {:ok, module, {:extension, owner, @policy_key}}
      :error -> configured_policy()
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

  defp runtime_policy do
    case Runtime.fetch(:context_policy, :default) do
      {:ok, value, owner} -> {:ok, value, owner}
      :error -> :error
    end
  end

  defp runtime_threshold(model_key) do
    case Runtime.fetch(:context_threshold, model_key) do
      {:ok, value, owner} -> {:ok, value, owner}
      :error -> :error
    end
  end

  defp first_runtime_threshold(keys) do
    Enum.find_value(keys, :missing, fn key ->
      case runtime_threshold(key) do
        {:ok, value, owner} ->
          {:ok, value, {:extension, owner, {:threshold, key}}}

        :error ->
          false
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

  # Shared derivation (id → api → :default) so prompt and threshold overlays
  # can't drift; this registry keeps its own `valid_model_key?/1` for
  # registration-time validation of caller-supplied keys.
  defp model_keys(model), do: Catalyst.Prompt.Config.model_keys(model)

  defp policy_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :threshold, 2) and
      function_exported?(module, :compact, 2)
  end

  defp policy_module?(_module), do: false

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
end
