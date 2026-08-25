defmodule Catalyst.Context.Compaction do
  @moduledoc """
  A context policy's proposed chronological transcript replacement.

  The replacement is advisory until `Catalyst.Context.Guard` validates the
  message shape and recomputes authoritative accounting for the staged request.
  """

  @enforce_keys [:replacement]
  defstruct [:replacement, :summary]

  @type t :: %__MODULE__{
          replacement: [Catalyst.Message.t()],
          summary: Catalyst.Message.User.t() | nil
        }
end

defmodule Catalyst.Context.Window do
  @moduledoc """
  Catalyst's provider-neutral context-window policy.

  Threshold resolution is exact and live: session option, runtime overlay,
  application configuration, then a conservative catalog/window fallback. The
  compactor removes only a complete old prefix and returns a staged replacement;
  `Catalyst.Context.Guard` performs the authoritative transformed-request check
  before anything is emitted or persisted. Transcript structure rules live in
  `Catalyst.Context.Transcript`; provider-backed summarization lives in
  `Catalyst.Context.Summarizer`.
  """

  @behaviour Catalyst.Context.Policy

  alias Catalyst.ExtensionAPI
  alias Catalyst.Message
  alias Catalyst.Context.{Compaction, Summarizer, Transcript}
  alias Catalyst.Runtime.Registry, as: Runtime

  @policy_key {:policy, :default}
  @threshold_sources [:session, :registry, :builtin]

  @type model_key :: String.t() | :default
  @type overlay_threshold :: :none | pos_integer() | float()

  @impl true
  @spec threshold(Catalyst.Model.t() | nil, map()) ::
          {:ok, pos_integer()} | :none | {:error, term()}
  def threshold(model, context) do
    case threshold_with_source(model, context) do
      {:ok, :none, _source} -> :none
      {:ok, value, _source} -> {:ok, value}
      :none -> :none
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Resolve a threshold together with the winning provenance layer.

  Sources are consulted in order (session option, runtime/application overlay,
  built-in catalog/ratio fallback). A raw `:none` means the winning source
  explicitly disabled compaction; a bare `:none` return means every source was
  missing.
  """
  @spec threshold_with_source(Catalyst.Model.t() | nil, map()) ::
          {:ok, pos_integer() | :none, term()} | :none | {:error, term()}
  def threshold_with_source(model, context) do
    window = effective_window(model)

    Enum.reduce_while(@threshold_sources, :none, fn source, none ->
      case threshold_source(source, model, window, context) do
        {:ok, raw, provenance} -> {:halt, normalize_threshold(raw, window, provenance)}
        :missing -> {:cont, none}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "The effective usable model window after the provider percentage contract."
  @spec effective_window(Catalyst.Model.t() | nil) :: {:ok, pos_integer()} | :error
  def effective_window(nil), do: :error

  def effective_window(model) do
    with {:ok, base} <- base_window(model),
         {:ok, ratio} <- effective_ratio(model),
         window when window > 0 <- floor(base * ratio) do
      {:ok, window}
    else
      _invalid -> :error
    end
  end

  @impl true
  @spec compact([Message.t()], map()) :: {:ok, Compaction.t()} | {:error, term()}
  def compact(messages, context) when is_list(messages) do
    with :ok <- Transcript.validate_transcript(messages),
         {:ok, threshold} <- fetch_positive(context, :threshold),
         {:ok, before} <- tokens_before(messages, context),
         units when length(units) > 1 <- Transcript.message_units(messages),
         {:ok, removed, kept, protected_count} <- initial_cut(units, threshold, context),
         {:ok, compaction} <-
           build_compaction(removed, kept, protected_count, before, threshold, context) do
      {:ok, compaction}
    else
      units when is_list(units) -> {:error, :irreducible_context}
      {:error, _reason} = error -> error
    end
  end

  @doc "Unique provider continuation namespace for one compaction attempt."
  @spec companion_id(String.t()) :: String.t()
  defdelegate companion_id(session_id), to: Summarizer

  @doc "Register the runtime default context policy."
  @spec register_policy(module(), keyword()) :: :ok | {:error, term()}
  def register_policy(module, opts \\ []) do
    with :ok <- validate_overlay(@policy_key, module) do
      Runtime.put(:context_policy, :default, module, Keyword.put(opts, :collision_key, nil))
    end
  end

  @doc "Register a runtime threshold for an exact model id/api or `:default`."
  @spec register_threshold(model_key(), overlay_threshold(), keyword()) ::
          :ok | {:error, term()}
  def register_threshold(model_key, value, opts \\ []) do
    with :ok <- validate_overlay({:threshold, model_key}, value) do
      Runtime.put(:context_threshold, model_key, value, opts)
    end
  end

  @doc "Remove the runtime policy overlay."
  @spec unregister_policy() :: :ok
  def unregister_policy, do: Runtime.delete(:context_policy, :default)

  @doc "Remove one runtime threshold overlay."
  @spec unregister_threshold(model_key()) :: :ok
  def unregister_threshold(model_key), do: Runtime.delete(:context_threshold, model_key)

  @doc "Resolve the effective context policy (runtime, live app config, built-in)."
  @spec policy() :: {:ok, module(), term()} | {:error, term()}
  def policy do
    case Runtime.fetch(:context_policy, :default) do
      {:ok, module, owner} -> {:ok, module, {:extension, owner, @policy_key}}
      :error -> configured_policy()
    end
  end

  @doc """
  Resolve an explicit threshold overlay for a model using exact id, api, then
  `:default`. Returns `:missing` when the built-in window strategy should run.
  """
  @spec overlay_threshold(Catalyst.Model.t() | nil) ::
          {:ok, overlay_threshold(), term()} | :missing | {:error, term()}
  def overlay_threshold(model) do
    keys = Catalyst.Prompt.model_keys(model)

    case first_runtime_threshold(keys) do
      {:ok, _value, _source} = found -> found
      :missing -> configured_threshold(keys)
    end
  end

  @doc false
  @spec builtin_threshold(Catalyst.Model.t() | nil) :: {:ok, pos_integer(), :builtin} | :missing
  def builtin_threshold(model), do: builtin_source(model, effective_window(model))

  @doc false
  @spec register_extension_policy(ExtensionAPI.t(), module(), keyword()) ::
          :ok | {:error, term()}
  def register_extension_policy(%ExtensionAPI{owner: owner}, module, opts) do
    register_policy(module, Keyword.put(opts, :owner, owner))
  end

  @doc false
  @spec register_extension_threshold(
          ExtensionAPI.t(),
          model_key(),
          overlay_threshold(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def register_extension_threshold(%ExtensionAPI{owner: owner}, model_key, value, opts) do
    register_threshold(model_key, value, Keyword.put(opts, :owner, owner))
  end

  defp threshold_source(:session, _model, _window, context) do
    opts = Map.get(context, :opts, []) || []

    cond do
      Map.has_key?(context, :context_threshold) ->
        {:ok, context.context_threshold, {:session, :context_threshold}}

      is_list(opts) and Keyword.has_key?(opts, :context_threshold) ->
        {:ok, Keyword.fetch!(opts, :context_threshold), {:session, :context_threshold}}

      true ->
        :missing
    end
  end

  defp threshold_source(:registry, model, _window, _context), do: overlay_threshold(model)

  defp threshold_source(:builtin, model, window, _context),
    do: builtin_source(model, window)

  defp builtin_source(model, window) do
    case Enum.filter(
           [catalog_limit(model, window), ratio_limit(window)],
           &positive_integer?/1
         ) do
      [] -> :missing
      limits -> {:ok, Enum.min(limits), :builtin}
    end
  end

  defp normalize_threshold(:none, _window, source), do: {:ok, :none, source}

  defp normalize_threshold(value, window, source) when is_integer(value) and value > 0 do
    case window do
      {:ok, limit} when value > limit ->
        {:error, {:context_threshold_exceeds_window, value, limit, source}}

      _usable_or_missing ->
        {:ok, value, source}
    end
  end

  defp normalize_threshold(value, {:ok, window}, source)
       when is_float(value) and value > 0.0 and value <= 1.0 do
    case floor(window * value) do
      resolved when resolved > 0 -> {:ok, resolved, source}
      _zero -> {:error, {:invalid_context_threshold, value, source}}
    end
  end

  defp normalize_threshold(value, :error, source)
       when is_float(value) and value > 0.0 and value <= 1.0,
       do: {:error, {:context_ratio_without_window, value, source}}

  defp normalize_threshold(value, _window, source),
    do: {:error, {:invalid_context_threshold, value, source}}

  defp base_window(model) do
    [Map.get(model, :context_window), Map.get(model, :max_context_window)]
    |> Enum.find(&positive_integer?/1)
    |> case do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp effective_ratio(model) do
    value = Map.get(model, :effective_context_window_percent)

    cond do
      is_nil(value) and Map.get(model, :api) == "openai-codex-responses" -> {:ok, 0.95}
      is_nil(value) -> {:ok, 1.0}
      is_integer(value) and value > 0 and value <= 100 -> {:ok, value / 100}
      is_float(value) and value > 0.0 and value <= 100.0 -> {:ok, value / 100.0}
      true -> :error
    end
  end

  defp catalog_limit(nil, _window), do: nil

  defp catalog_limit(model, window) do
    limit = Map.get(model, :auto_compact_token_limit)

    cond do
      not positive_integer?(limit) -> nil
      match?({:ok, _}, window) -> min(limit, floor(elem(window, 1) * 0.90))
      true -> limit
    end
  end

  defp ratio_limit({:ok, window}), do: floor(window * 0.70)
  defp ratio_limit(:error), do: nil

  defp fetch_positive(context, key) do
    case Map.get(context, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, {:invalid_compaction_context, key, value}}
    end
  end

  defp tokens_before(messages, context) do
    case Map.get(context, :tokens_before) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      nil -> {:ok, estimate_messages(messages, context)}
      value -> {:error, {:invalid_compaction_context, :tokens_before, value}}
    end
  end

  defp initial_cut(units, threshold, context) do
    protected_count = min(length(units), automatic_protected_unit_count(units))

    case length(units) > protected_count do
      false ->
        {:error, :irreducible_context}

      true ->
        budget = min(20_000, floor(threshold * 0.25))
        kept_count = grow_kept_count(units, protected_count, budget, context)
        split = length(units) - kept_count
        {removed, kept} = Enum.split(units, split)
        {:ok, List.flatten(removed), List.flatten(kept), protected_count}
    end
  end

  defp grow_kept_count(units, protected_count, budget, context) do
    max_count = length(units) - 1

    Enum.reduce_while(protected_count..max_count, protected_count, fn count, _current ->
      kept = units |> Enum.take(-count) |> List.flatten()

      case estimate_messages(kept, context) <= budget do
        true -> {:cont, count}
        false -> {:halt, max(protected_count, count - 1)}
      end
    end)
  end

  defp build_compaction(removed, kept, protected_count, before, threshold, context) do
    target = max(1, floor(threshold * 0.75))
    summary = Summarizer.summarize(removed, context)

    case fit_candidate(summary, kept, protected_count, before, target, threshold, context) do
      {:ok, replacement, accepted_summary, _after_tokens} ->
        {:ok, %Compaction{replacement: replacement, summary: accepted_summary}}

      {:error, _reason} ->
        case fit_candidate(nil, kept, protected_count, before, target, threshold, context) do
          {:ok, replacement, nil, _after_tokens} ->
            {:ok, %Compaction{replacement: replacement}}

          {:error, _reason} ->
            {:error, :irreducible_context}
        end
    end
  end

  defp fit_candidate(summary, kept, protected_count, before, target, threshold, context) do
    protected = protected_suffix(kept, protected_count)
    do_fit_candidate(summary, kept, protected, before, target, threshold, context)
  end

  defp do_fit_candidate(summary, kept, protected, before, target, threshold, context) do
    replacement = List.wrap(summary) ++ kept

    case {fit_tokens(replacement, before, context), summary, kept == protected} do
      {{:ok, tokens}, _summary, _protected_only?} when tokens <= target ->
        {:ok, replacement, summary, tokens}

      {_fit, summary, _protected_only?} when not is_nil(summary) ->
        {:error, :summary_missed_target}

      {{:ok, tokens}, nil, true} when tokens < threshold ->
        {:ok, replacement, nil, tokens}

      {_fit, nil, true} ->
        {:error, :irreducible_context}

      {_fit, nil, false} ->
        [_drop | tighter] = Transcript.message_units(kept)

        do_fit_candidate(
          nil,
          List.flatten(tighter),
          protected,
          before,
          target,
          threshold,
          context
        )
    end
  end

  defp fit_tokens(replacement, before, context) do
    with {:ok, tokens} when tokens < before <- estimate_replacement(replacement, context),
         true <- Transcript.valid_transcript?(replacement) do
      {:ok, tokens}
    else
      _oversized_invalid_or_failed -> :unfit
    end
  end

  defp protected_suffix(messages, count) do
    messages
    |> Transcript.message_units()
    |> Enum.take(-count)
    |> List.flatten()
  end

  defp estimate_replacement(messages, context) do
    case Map.get(context, :estimate_replacement) do
      fun when is_function(fun, 1) -> normalize_estimate(fun.(messages))
      fun when is_function(fun, 2) -> normalize_estimate(fun.(messages, context))
      _none -> {:ok, estimate_messages(messages, context)}
    end
  end

  defp normalize_estimate({:ok, tokens}) when is_integer(tokens) and tokens >= 0,
    do: {:ok, tokens}

  defp normalize_estimate(tokens) when is_integer(tokens) and tokens >= 0, do: {:ok, tokens}
  defp normalize_estimate({:error, _reason} = error), do: error
  defp normalize_estimate(invalid), do: {:error, {:invalid_replacement_estimate, invalid}}

  defp estimate_messages(messages, context) do
    base = Map.get(context, :base_tokens, 0)

    bytes =
      messages
      |> Enum.map(&Summarizer.render_message/1)
      |> IO.iodata_to_binary()
      |> byte_size()

    base + div(bytes + 3, 4)
  end

  defp automatic_protected_unit_count([]), do: 0

  defp automatic_protected_unit_count(units) do
    last_index = length(units) - 1
    last_unit = Enum.at(units, last_index)

    start_index =
      case user_unit?(last_unit) do
        true -> latest_assistant_unit_index(units, last_index - 1) || last_index
        false -> latest_assistant_unit_index(units, last_index) || last_index
      end

    length(units) - start_index
  end

  defp latest_assistant_unit_index(_units, before_index) when before_index < 0, do: nil

  defp latest_assistant_unit_index(units, before_index) do
    units
    |> Enum.with_index()
    |> Enum.take(before_index + 1)
    |> Enum.reverse()
    |> Enum.find_value(fn
      {[%Message.Assistant{} | _rest], index} -> index
      _other -> nil
    end)
  end

  defp user_unit?([%Message.User{}]), do: true
  defp user_unit?(_unit), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp validate_overlay(@policy_key = key, module) do
    case policy_module?(module) do
      true -> :ok
      false -> {:error, {:invalid_registration, key, module}}
    end
  end

  defp validate_overlay({:threshold, model_key} = key, value) do
    case valid_overlay_key?(model_key) and valid_overlay_threshold?(value) do
      true -> :ok
      false -> {:error, {:invalid_registration, key, value}}
    end
  end

  defp valid_overlay_threshold?(:none), do: true
  defp valid_overlay_threshold?(value) when is_integer(value), do: value > 0
  defp valid_overlay_threshold?(value) when is_float(value), do: value > 0.0 and value <= 1.0
  defp valid_overlay_threshold?(_value), do: false

  defp valid_overlay_key?(:default), do: true
  defp valid_overlay_key?(key) when is_binary(key), do: String.trim(key) != ""
  defp valid_overlay_key?(_key), do: false

  defp first_runtime_threshold(keys) do
    Enum.find_value(keys, :missing, fn key ->
      case Runtime.fetch(:context_threshold, key) do
        {:ok, value, owner} -> {:ok, value, {:extension, owner, {:threshold, key}}}
        :error -> false
      end
    end)
  end

  defp configured_policy do
    module = Application.get_env(:catalyst, :context_policy, __MODULE__)

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
      case valid_overlay_key?(key) and valid_overlay_threshold?(value) do
        true -> {:cont, :ok}
        false -> {:halt, {:error, {:invalid_configuration, :context_thresholds, {key, value}}}}
      end
    end)
  end

  defp policy_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :threshold, 2) and
      function_exported?(module, :compact, 2)
  end

  defp policy_module?(_module), do: false
end
