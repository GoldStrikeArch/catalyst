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
    "faux" => Catalyst.LLM.Faux,
    "openai-codex-responses" => Catalyst.LLM.OpenAICodex.Provider
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

  def register_provider(api, module, opts) when is_binary(api) and is_atom(module),
    do: register_provider(api, %ProviderConfig{module: module}, opts)

  @doc "Remove a provider (restoring a built-in/config one if it was shadowed)."
  @spec unregister_provider(String.t()) :: :ok
  def unregister_provider(api) when is_binary(api), do: Runtime.delete(:provider, api)

  @doc "Remove every provider registered by `owner` (extension purge hook)."
  @spec unregister_owner(term()) :: :ok
  def unregister_owner(owner), do: Runtime.purge_owner(owner, :provider)

  defp register(api, config, opts) do
    with :ok <- validate_provider_module(config.module) do
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

  # ---- internals ------------------------------------------------------------

  defp lookup(api) do
    case Runtime.fetch(:provider, api) do
      {:ok, config, _owner} -> config
      :error -> Map.get(seed_map(), api)
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
  @spec wire_extension_api() :: :ok
  def wire_extension_api do
    ExtensionAPI.register_kind(:provider, &__MODULE__.register_extension_provider/3)
    :ok
  end
end
