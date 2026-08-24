defmodule Catalyst.Prompt.Registry do
  @moduledoc """
  Prompt resolution and registration over the shared runtime contribution store.

  Only runtime registrations live in `Catalyst.Runtime.Registry`. Reads fall through to the current
  application configuration, so post-boot changes remain visible and removing
  an overlay never restores a stale startup snapshot.
  """

  alias Catalyst.ExtensionAPI
  alias Catalyst.Prompt.Config
  alias Catalyst.Runtime.Registry, as: Runtime

  @policy_key {:policy, :default}

  @type model_key :: Config.model_key()
  @type purpose :: Config.purpose()
  @type key :: {:policy, :default} | {:text, purpose(), model_key()}
  @type source ::
          {:extension, term(), key()}
          | {:application, term()}
          | :builtin

  @doc "Register model- and purpose-specific prompt text as a runtime overlay."
  @spec register_prompt(model_key(), binary(), keyword()) :: :ok | {:error, term()}
  def register_prompt(model_key, text, opts \\ []) do
    purpose = Keyword.get(opts, :purpose, :system)
    register({:text, purpose, model_key}, text, opts)
  end

  @doc "Register the runtime-default prompt policy."
  @spec register_policy(module(), keyword()) :: :ok | {:error, term()}
  def register_policy(module, opts \\ []), do: register(@policy_key, module, opts)

  @doc "Remove one runtime overlay, revealing the current lower-precedence layer."
  @spec unregister(key()) :: :ok
  def unregister(key), do: Runtime.delete(:prompt, key)

  @doc "Remove the runtime prompt-policy overlay."
  @spec unregister_policy() :: :ok
  def unregister_policy, do: unregister(@policy_key)

  @doc "Remove every runtime overlay owned by owner."
  @spec unregister_owner(term()) :: :ok
  def unregister_owner(owner), do: Runtime.purge_owner(owner, :prompt)

  # test seam. Resolves one text layer through runtime and live application
  # configuration. Built-in policy file and text fallbacks are intentionally
  # handled by Catalyst.SystemPrompt so its documented file layers can sit
  # between application configuration and built-in text.
  @doc false
  @spec lookup_text(purpose(), model_key()) ::
          {:ok, binary(), source()} | :error | {:error, term()}
  def lookup_text(purpose, model_key) do
    key = {:text, purpose, model_key}

    case lookup_runtime(key) do
      {:ok, text, owner} ->
        {:ok, text, {:extension, owner, key}}

      :error ->
        application_text(purpose, model_key)
    end
  end

  @doc "Read only the runtime text overlay and its owner."
  @spec runtime_text(purpose(), model_key()) :: {:ok, binary(), term()} | :error
  def runtime_text(purpose, model_key), do: lookup_runtime({:text, purpose, model_key})

  @doc "Resolve the current prompt policy and the layer that selected it."
  @spec policy() :: {:ok, module(), source()} | {:error, term()}
  def policy do
    case lookup_runtime(@policy_key) do
      {:ok, module, owner} ->
        {:ok, module, {:extension, owner, @policy_key}}

      :error ->
        application_policy()
    end
  end

  # test seam: compatibility projection returning only the effective policy module.
  @doc false
  @spec fetch_policy() :: {:ok, module()} | {:error, term()}
  def fetch_policy do
    case policy() do
      {:ok, module, _source} -> {:ok, module}
      {:error, _reason} = error -> error
    end
  end

  @doc "Return sorted owner-aware runtime registrations; fallback layers are excluded."
  @spec runtime_entries() :: [%{key: key(), value: term(), owner: term()}]
  def runtime_entries do
    Enum.map(Runtime.list(:prompt), fn entry ->
      %{key: entry.key, value: entry.value, owner: entry.owner}
    end)
  end

  defp register(key, value, opts) do
    with :ok <- validate_registration(key, value) do
      Runtime.put(:prompt, key, value, opts)
    end
  end

  defp lookup_runtime(key) do
    case Runtime.fetch(:prompt, key) do
      {:ok, value, owner} -> {:ok, value, owner}
      :error -> :error
    end
  end

  defp application_text(purpose, model_key) do
    case Config.lookup(purpose, model_key) do
      {:ok, text} -> {:ok, text, {:application, {:prompts, purpose, model_key}}}
      :error -> :error
      {:error, _reason} = error -> error
    end
  end

  defp application_policy do
    case Application.fetch_env(:catalyst, :prompt_policy) do
      :error ->
        {:ok, Catalyst.SystemPrompt, :builtin}

      {:ok, module} ->
        case valid_policy?(module) do
          true -> {:ok, module, {:application, :prompt_policy}}
          false -> {:error, {:invalid_prompt_policy, module}}
        end
    end
  end

  defp validate_registration(@policy_key = key, module) do
    case valid_policy?(module) do
      true -> :ok
      false -> invalid_registration(key, module)
    end
  end

  defp validate_registration({:text, purpose, model_key} = key, text) do
    case Config.valid_purpose?(purpose) and Config.valid_model_key?(model_key) and
           Config.nonblank_text?(text) do
      true -> :ok
      false -> invalid_registration(key, text)
    end
  end

  defp invalid_registration(key, value),
    do: {:error, {:invalid_registration, key, value}}

  defp valid_policy?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :resolve, 1)
  end

  defp valid_policy?(_module), do: false

  @doc false
  @spec register_extension_prompt(ExtensionAPI.t(), model_key(), binary(), keyword()) ::
          :ok | {:error, term()}
  def register_extension_prompt(%ExtensionAPI{owner: owner}, model_key, text, opts) do
    register_prompt(model_key, text, Keyword.put(opts, :owner, owner))
  end

  @doc false
  @spec register_extension_prompt_policy(ExtensionAPI.t(), module(), keyword()) ::
          :ok | {:error, term()}
  def register_extension_prompt_policy(%ExtensionAPI{owner: owner}, module, opts) do
    register_policy(module, Keyword.put(opts, :owner, owner))
  end

  @doc false
  @spec wire_extension_api() :: :ok
  def wire_extension_api do
    ExtensionAPI.register_kind(:prompt, &__MODULE__.register_extension_prompt/4)

    ExtensionAPI.register_kind(
      :prompt_policy,
      &__MODULE__.register_extension_prompt_policy/3
    )

    :ok
  end
end
