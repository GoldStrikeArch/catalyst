defmodule Catalyst.Context.Window do
  @moduledoc """
  Catalyst's provider-neutral context-window policy.

  Threshold resolution is exact and live: session option, runtime registry,
  application configuration, then a conservative catalog/window fallback.  The
  compactor removes only a complete old prefix and returns a staged replacement;
  `Catalyst.Context.Guard` performs the authoritative transformed-request check
  before anything is emitted or persisted.  Transcript structure rules live in
  `Catalyst.Context.Transcript`; provider-backed summarization lives in
  `Catalyst.Context.Summarizer`.
  """

  @behaviour Catalyst.Context.Policy

  alias Catalyst.Message
  alias Catalyst.Context.{Compaction, Registry, Summarizer, Transcript}

  # Ordered threshold resolution: the first source producing a value wins and
  # is normalized against the model's effective window. This literal list is
  # the resolution order.
  @threshold_sources [:session, :registry, :builtin]

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

  Sources are consulted in order (session option, runtime/application
  registry, built-in catalog/ratio fallback); each returns
  `{:ok, raw, source} | :missing | {:error, reason}`.  A raw `:none` means the
  winning source explicitly disabled compaction and keeps that source's
  provenance; a bare `:none` return means every source was missing — no window
  and no catalog limit exist, so no threshold can apply.
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

  @doc false
  @spec builtin_threshold(Catalyst.Model.t() | nil, boolean()) ::
          {:ok, pos_integer(), :builtin} | :missing
  def builtin_threshold(model, anchored?),
    do: builtin_source(model, effective_window(model), anchored?)

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

  defp threshold_source(:registry, model, _window, _context), do: Registry.threshold(model)

  defp threshold_source(:builtin, model, window, context),
    do: builtin_source(model, window, Map.get(context, :anchored, false))

  defp builtin_source(model, window, anchored?) do
    case Enum.filter(
           [catalog_limit(model, window), ratio_limit(window, anchored?)],
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

  defp ratio_limit({:ok, window}, anchored?),
    do: floor(window * if(anchored?, do: 0.85, else: 0.70))

  defp ratio_limit(:error, _anchored?), do: nil

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
        # A failed/oversized summary is not fatal.  Retry the same deterministic
        # whole-unit tightening without it before declaring the suffix irreducible.
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

  # A candidate fits only when its estimate succeeded, shrinks the transcript,
  # and the replacement stays structurally valid. A failed estimate is a
  # tagged miss (`:unfit`) rather than a huge sentinel token count.
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

  # Estimator seams may return a raw count (tests, simple policies) or the
  # tagged `Catalyst.Context.Tokens.estimate_tokens/3` result (the guard).
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
end
