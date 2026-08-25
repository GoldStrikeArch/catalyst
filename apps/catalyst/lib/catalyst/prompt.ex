defmodule Catalyst.Prompt.Request do
  @moduledoc "An immutable prompt-resolution request."

  defstruct purpose: :system,
            model: nil,
            cwd: nil,
            session_id: nil,
            override: nil,
            opts: []

  @type purpose :: :system | :compaction

  @type t :: %__MODULE__{
          purpose: purpose(),
          model: Catalyst.Model.t() | nil,
          cwd: Path.t() | nil,
          session_id: String.t() | nil,
          override: String.t() | nil,
          opts: keyword()
        }
end

defmodule Catalyst.Prompt.Resolution do
  @moduledoc "A resolved prompt together with its digest and ordered provenance."

  alias Catalyst.Tools.Truncate

  @enforce_keys [:text, :sources, :digest]
  defstruct [:text, :sources, :digest]

  @type source ::
          {:session, :override}
          | {:extension, term(), term()}
          | {:application, term()}
          | {:file, Path.t()}
          | {:hook, :prepare_next_turn}
          | :builtin

  @type t :: %__MODULE__{
          text: String.t(),
          sources: [source()],
          digest: String.t()
        }

  @doc "Build a resolution, repairing UTF-8 before computing its SHA-256 digest."
  @spec new(binary(), [source()]) :: t()
  def new(text, sources) when is_binary(text) and is_list(sources) do
    text = Truncate.scrub_utf8(text)
    %__MODULE__{text: text, sources: sources, digest: digest(text)}
  end

  @doc false
  @spec valid_sources?(term()) :: boolean()
  def valid_sources?(sources) when is_list(sources), do: Enum.all?(sources, &valid_source?/1)
  def valid_sources?(_sources), do: false

  @doc false
  @spec valid_source?(term()) :: boolean()
  def valid_source?(:builtin), do: true
  def valid_source?({:session, :override}), do: true
  def valid_source?({:extension, _owner, _key}), do: true
  def valid_source?({:application, _key}), do: true
  def valid_source?({:file, path}) when is_binary(path), do: true
  def valid_source?({:hook, :prepare_next_turn}), do: true
  def valid_source?(_source), do: false

  @doc "Return the lowercase hexadecimal SHA-256 digest of prompt text."
  @spec digest(binary()) :: String.t()
  def digest(text) when is_binary(text) do
    :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
  end
end

defmodule Catalyst.Prompt do
  @moduledoc """
  Resolves purpose-aware prompts and owns live `:prompts` / overlay lookup.

  Policy selection is runtime overlay, then `:prompt_policy` app env, then
  `Catalyst.SystemPrompt`. Extension policies must run from supervised workers.
  """

  alias Catalyst.ExtensionAPI
  alias Catalyst.{Tasks, Tools}
  alias Catalyst.Prompt.{Request, Resolution}
  alias Catalyst.Runtime.Registry, as: Runtime

  @default_policy_timeout 5_000
  @policy_key {:policy, :default}
  @purposes [:system, :compaction]

  @type purpose :: :system | :compaction
  @type model_key :: String.t() | :default

  @doc "Resolve a complete prompt and ordered provenance for one request."
  @callback resolve(Request.t()) :: {:ok, Resolution.t()} | {:error, term()}

  @doc "Resolve `request` with the current runtime, application, or built-in policy."
  @spec resolve(Request.t()) :: {:ok, Resolution.t()} | {:error, term()}
  def resolve(%Request{} = request) do
    with {:ok, policy, _source} <- policy() do
      policy.resolve(request)
    end
  end

  @doc "Resolve through a supervised, bounded policy call and normalize its result."
  @spec resolve_bounded(Request.t(), timeout()) :: {:ok, Resolution.t()} | {:error, term()}
  def resolve_bounded(%Request{} = request, timeout \\ policy_timeout()) do
    task = Tasks.async(fn -> resolve(request) end)

    case Tasks.await(task, timeout) do
      {:ok, {:ok, %Resolution{} = resolution}} -> normalize_resolution(resolution)
      {:ok, {:error, reason}} -> {:error, {:prompt_resolution, reason}}
      {:ok, invalid} -> {:error, {:invalid_prompt_policy_return, invalid}}
      {:exit, reason} -> {:error, {:prompt_policy_exit, reason}}
      :timeout -> {:error, :prompt_policy_timeout}
    end
  end

  @doc """
  Scrub UTF-8, reject blank text and invalid provenance, and recompute the digest.

  `Session.RunContext` uses this for hook-installed prompts as well.
  """
  @spec normalize_resolution(term()) :: {:ok, Resolution.t()} | {:error, term()}
  def normalize_resolution(%Resolution{text: text, sources: sources})
      when is_binary(text) and is_list(sources) do
    resolution = Resolution.new(Tools.Truncate.scrub_utf8(text), sources)

    cond do
      String.trim(resolution.text) == "" -> {:error, :blank_prompt_resolution}
      not Resolution.valid_sources?(sources) -> invalid_provenance(sources)
      true -> {:ok, resolution}
    end
  end

  def normalize_resolution(resolution),
    do: {:error, {:invalid_prompt_resolution, resolution}}

  @doc "Read one prompt from the current `:prompts` application setting."
  @spec lookup(purpose(), model_key()) :: {:ok, binary()} | :error | {:error, term()}
  def lookup(purpose, model_key) do
    :catalyst |> Application.get_env(:prompts, %{}) |> lookup(purpose, model_key)
  end

  @doc "Validate and read one prompt from an explicit configuration map."
  @spec lookup(term(), purpose(), model_key()) :: {:ok, binary()} | :error | {:error, term()}
  def lookup(config, purpose, model_key) do
    with :ok <- validate(config),
         :ok <- validate_lookup(purpose, model_key) do
      fetch_text(config, purpose, model_key)
    end
  end

  @doc "Validate the complete purpose-aware prompt configuration."
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(config) when is_map(config) do
    config
    |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
    |> Enum.reduce_while(:ok, &validate_purpose/2)
  end

  def validate(config), do: invalid_config({:expected_map, config})

  @doc "Ordered lookup keys for a model: its id, its api, then `:default`."
  @spec model_keys(term()) :: [term()]
  def model_keys(nil), do: [:default]

  def model_keys(model) when is_map(model) do
    [Map.get(model, :id), Map.get(model, :api), :default]
    |> Enum.filter(&valid_model_key?/1)
    |> Enum.uniq()
  end

  def model_keys(_model), do: [:default]

  @doc "True when `text` is nonblank after UTF-8 repair."
  @spec nonblank_text?(term()) :: boolean()
  def nonblank_text?(text) when is_binary(text) do
    text |> Tools.Truncate.scrub_utf8() |> String.trim() != ""
  end

  def nonblank_text?(_text), do: false

  @doc false
  @spec valid_purpose?(term()) :: boolean()
  def valid_purpose?(purpose), do: purpose in @purposes

  @doc false
  @spec valid_model_key?(term()) :: boolean()
  def valid_model_key?(:default), do: true

  def valid_model_key?(model_key) when is_binary(model_key) do
    model_key |> Tools.Truncate.scrub_utf8() |> String.trim() != ""
  end

  def valid_model_key?(_model_key), do: false

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
  @spec unregister(term()) :: :ok
  def unregister(key), do: Runtime.delete(:prompt, key)

  @doc "Remove the runtime prompt-policy overlay."
  @spec unregister_policy() :: :ok
  def unregister_policy, do: unregister(@policy_key)

  @doc "Read only the runtime text overlay and its owner."
  @spec runtime_text(purpose(), model_key()) :: {:ok, binary(), term()} | :error
  def runtime_text(purpose, model_key) do
    case Runtime.fetch(:prompt, {:text, purpose, model_key}) do
      {:ok, value, owner} -> {:ok, value, owner}
      :error -> :error
    end
  end

  @doc "Resolve the current prompt policy and the layer that selected it."
  @spec policy() :: {:ok, module(), term()} | {:error, term()}
  def policy do
    case Runtime.fetch(:prompt, @policy_key) do
      {:ok, module, owner} -> {:ok, module, {:extension, owner, @policy_key}}
      :error -> application_policy()
    end
  end

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

  defp register(key, value, opts) do
    with :ok <- validate_registration(key, value), do: Runtime.put(:prompt, key, value, opts)
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
    case valid_purpose?(purpose) and valid_model_key?(model_key) and nonblank_text?(text) do
      true -> :ok
      false -> invalid_registration(key, text)
    end
  end

  defp valid_policy?(module) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :resolve, 1)

  defp valid_policy?(_module), do: false

  defp validate_purpose({purpose, entries}, :ok) do
    cond do
      not valid_purpose?(purpose) -> {:halt, invalid_config({:unknown_purpose, purpose})}
      not is_map(entries) -> {:halt, invalid_config({:expected_purpose_map, purpose, entries})}
      true -> continue_validation(validate_entries(purpose, entries))
    end
  end

  defp validate_entries(purpose, entries) do
    entries
    |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
    |> Enum.reduce_while(:ok, fn {model_key, text}, :ok ->
      cond do
        not valid_model_key?(model_key) ->
          {:halt, invalid_config({:invalid_model_key, purpose, model_key})}

        not is_binary(text) ->
          {:halt, invalid_config({:invalid_text, purpose, model_key, text})}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_lookup(purpose, model_key) do
    cond do
      not valid_purpose?(purpose) -> invalid_config({:unknown_purpose, purpose})
      not valid_model_key?(model_key) -> invalid_config({:invalid_model_key, purpose, model_key})
      true -> :ok
    end
  end

  defp fetch_text(config, purpose, model_key) do
    with {:ok, purpose_entries} <- Map.fetch(config, purpose),
         {:ok, text} <- Map.fetch(purpose_entries, model_key) do
      selected_text(text, purpose, model_key)
    else
      :error -> :error
    end
  end

  defp selected_text(text, purpose, model_key) do
    case nonblank_text?(text) do
      true -> {:ok, text}
      false -> invalid_config({:blank_text, purpose, model_key})
    end
  end

  defp continue_validation(:ok), do: {:cont, :ok}
  defp continue_validation({:error, _reason} = error), do: {:halt, error}

  defp invalid_config(reason), do: {:error, {:invalid_prompt_config, reason}}
  defp invalid_registration(key, value), do: {:error, {:invalid_registration, key, value}}

  defp invalid_provenance(sources) do
    invalid = Enum.find(sources, &(not Resolution.valid_source?(&1)))
    {:error, {:invalid_prompt_provenance, invalid}}
  end

  defp policy_timeout,
    do: Application.get_env(:catalyst, :prompt_policy_timeout, @default_policy_timeout)
end
