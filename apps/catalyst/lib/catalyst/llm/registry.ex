defmodule Catalyst.LLM.Registry do
  @moduledoc """
  Runtime resolver mapping a model's `api` string to its provider. Built-ins
  and `config :catalyst, :llm_providers` remain live fallback layers, and
  the shared runtime contribution store is writable at
  runtime (`register_provider/3`) so an extension can add a new provider — or
  override an existing one — with no restart.

  Refactoring an existing provider needs no registry change at all: recompiling
  its module hot-swaps the code, and the next `stream/4` call runs the new
  version. The registry is for *adding/selecting* providers by name.
  """

  alias Catalyst.ExtensionAPI
  alias Catalyst.LLM.ProviderConfig
  alias Catalyst.Runtime.Registry, as: Runtime

  @builtin %{
    "faux" => %ProviderConfig{module: Catalyst.LLM.Faux, name: "faux"},
    "openai-codex-responses" => %ProviderConfig{
      module: Catalyst.LLM.OpenAICodex.Provider,
      name: "openai-codex-responses",
      controls: Catalyst.LLM.OpenAICodex.Controls
    }
  }

  # ---- API ------------------------------------------------------------------

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
    runtime =
      Runtime.list(:provider)
      |> Map.new(fn entry -> {entry.key, entry.value} end)

    Map.merge(seed_map(), runtime)
  end

  @doc """
  Register (or replace) a provider under `api`. Accepts a `%ProviderConfig{}` or a
  bare provider module. `opts[:owner]` tags it for purge-on-reload.
  """
  @spec register_provider(String.t(), ProviderConfig.t() | module(), keyword()) ::
          :ok | {:error, term()}
  def register_provider(api, config, opts \\ [])

  def register_provider(api, %ProviderConfig{} = config, opts) when is_binary(api),
    do: register(api, config, opts)

  def register_provider(api, module, opts) when is_binary(api) and is_atom(module) do
    config =
      case lookup(api) do
        %ProviderConfig{} = current -> %{current | module: module}
        nil -> %ProviderConfig{module: module}
      end

    register_provider(api, config, opts)
  end

  @doc "Remove a provider (restoring a built-in/config one if it was shadowed)."
  @spec unregister_provider(String.t()) :: :ok
  def unregister_provider(api) when is_binary(api), do: Runtime.delete(:provider, api)

  @doc "Remove every provider registered by `owner` (extension purge hook)."
  @spec unregister_owner(term()) :: :ok
  def unregister_owner(owner), do: Runtime.purge_owner(owner, :provider)

  defp register(api, config, opts) do
    with :ok <- validate_provider_module(config.module),
         :ok <- validate_controls_module(config.controls) do
      Runtime.put(:provider, api, config, opts)
    end
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

  defp validate_controls_module(nil), do: :ok

  defp validate_controls_module(module) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         [] <-
           Enum.reject(
             Catalyst.LLM.Controls.callbacks(),
             &function_exported?(module, elem(&1, 0), elem(&1, 1))
           ) do
      :ok
    else
      {:error, _reason} -> {:error, {:controls_module_not_found, module}}
      missing -> {:error, {:missing_controls_callbacks, module, missing}}
    end
  end

  defp validate_controls_module(_module), do: {:error, :invalid_controls_module}

  # ---- internals ------------------------------------------------------------

  defp lookup(api) do
    case Runtime.fetch(:provider, api) do
      {:ok, config, _owner} -> config
      :error -> Map.get(seed_map(), api)
    end
  end

  defp seed_map do
    overrides =
      :catalyst
      |> Application.get_env(:llm_providers, %{})
      |> Map.new(fn {api, v} -> {api, normalize(v)} end)

    Map.merge(@builtin, overrides)
  end

  defp normalize(%ProviderConfig{} = config), do: config
  defp normalize(module) when is_atom(module), do: %ProviderConfig{module: module}

  @doc false
  @spec register_extension_provider(ExtensionAPI.t(), String.t(), ProviderConfig.t() | module()) ::
          :ok | {:error, term()}
  def register_extension_provider(%ExtensionAPI{owner: owner}, api, config) do
    register_provider(api, config, owner: owner)
  end

  @doc false
  @spec wire_extension_api() :: :ok
  def wire_extension_api do
    ExtensionAPI.register_kind(:provider, &__MODULE__.register_extension_provider/3)
    :ok
  end
end
