defmodule Catalyst.Prompt.Registry do
  @moduledoc """
  Owner-aware runtime overlays for prompt text and prompt policies.

  Only runtime registrations live in ETS. Reads fall through to the current
  application configuration, so post-boot changes remain visible and removing
  an overlay never restores a stale startup snapshot.
  """

  use GenServer

  alias Catalyst.ExtensionAPI
  alias Catalyst.Extensions.Owner
  alias Catalyst.Prompt.Config

  @table :catalyst_prompt_registry
  @policy_key {:policy, :default}

  @type model_key :: Config.model_key()
  @type purpose :: Config.purpose()
  @type key :: {:policy, :default} | {:text, purpose(), model_key()}
  @type source ::
          {:extension, term(), key()}
          | {:application, term()}
          | :builtin

  @doc "Start the singleton prompt registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

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
  def unregister(key), do: GenServer.call(__MODULE__, {:unregister, key})

  @doc "Remove the runtime prompt-policy overlay."
  @spec unregister_policy() :: :ok
  def unregister_policy, do: unregister(@policy_key)

  @doc "Remove every runtime overlay owned by owner."
  @spec unregister_owner(term()) :: :ok
  def unregister_owner(owner), do: GenServer.call(__MODULE__, {:unregister_owner, owner})

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
    case table_rows() do
      {:ok, rows} ->
        rows
        |> Enum.map(fn {key, value, owner} -> %{key: key, value: value, owner: owner} end)
        |> Enum.sort_by(&inspect(&1.key))

      :error ->
        []
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    wire_extension_api()
    {:ok, :ok}
  end

  @impl true
  def handle_call({:register, key, value, opts}, _from, state) do
    owner = opts |> Keyword.get(:owner) |> Owner.normalize()

    with :ok <- validate_registration(key, value),
         :ok <- claim(key, owner) do
      :ets.insert(@table, {key, value, owner})
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  def handle_call({:unregister_owner, owner}, _from, state) do
    :ets.match_delete(@table, {:_, :_, owner})
    {:reply, :ok, state}
  end

  defp register(key, value, opts),
    do: GenServer.call(__MODULE__, {:register, key, value, opts})

  defp lookup_runtime(key) do
    case lookup_row(key) do
      [{^key, value, owner}] -> {:ok, value, owner}
      _missing -> :error
    end
  end

  # The rescues wrap only the :ets call: readers keep their documented
  # fallback while the table is absent; a malformed row must not silently
  # read as "no overlays".
  defp lookup_row(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  defp table_rows do
    {:ok, :ets.tab2list(@table)}
  rescue
    ArgumentError -> :error
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

  defp validate_registration(key, value), do: invalid_registration(key, value)

  defp invalid_registration(key, value),
    do: {:error, {:invalid_registration, key, value}}

  # Ownership lives in ETS column 3 (single writer: this process), so a claim
  # is a plain lookup — no second bookkeeping structure to desync.
  defp claim(key, owner) do
    case lookup_runtime(key) do
      :error -> :ok
      {:ok, _value, ^owner} -> :ok
      {:ok, _value, existing} -> {:error, {:owner_collision, :prompt, key, existing, owner}}
    end
  end

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

  defp wire_extension_api do
    ExtensionAPI.register_kind(:prompt, &__MODULE__.register_extension_prompt/4)

    ExtensionAPI.register_kind(
      :prompt_policy,
      &__MODULE__.register_extension_prompt_policy/3
    )

    ExtensionAPI.register_purger(&__MODULE__.unregister_owner/1)
  end
end
