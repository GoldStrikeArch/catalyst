defmodule Catalyst.Context.Window do
  @moduledoc """
  Catalyst's provider-neutral context-window policy.

  Threshold resolution is exact and live: session option, runtime registry,
  application configuration, then a conservative catalog/window fallback.  The
  compactor removes only a complete old prefix and returns a staged replacement;
  `Catalyst.Context.Guard` performs the authoritative transformed-request check
  before anything is emitted or persisted.
  """

  @behaviour Catalyst.Context.Policy

  alias Catalyst.{Content, Message, Tasks}
  alias Catalyst.Context.{Compaction, Registry}
  alias Catalyst.LLM.Context, as: LLMContext
  alias Catalyst.Tools.Truncate

  @summary_prefix "[Compacted context summary]\n"
  @summary_result_limit 16_000
  @tool_result_limit 2_000
  @default_policy_timeout 30_000

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

  @doc "Resolve a threshold together with the winning provenance layer."
  @spec threshold_with_source(Catalyst.Model.t() | nil, map()) ::
          {:ok, pos_integer() | :none, term()} | :none | {:error, term()}
  def threshold_with_source(model, context) do
    window = effective_window(model)

    case session_threshold(context) do
      :missing -> registry_or_builtin(model, window, Map.get(context, :anchored, false))
      {:ok, value} -> normalize_threshold(value, window, {:session, :context_threshold})
    end
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
    with :ok <- validate_transcript(messages),
         {:ok, threshold} <- fetch_positive(context, :threshold),
         {:ok, before} <- tokens_before(messages, context),
         units when length(units) > 1 <- message_units(messages),
         {:ok, removed, kept, protected_count} <- initial_cut(units, threshold, context),
         {:ok, compaction} <-
           build_compaction(removed, kept, protected_count, before, threshold, context) do
      {:ok, compaction}
    else
      units when is_list(units) -> {:error, :irreducible_context}
      {:error, _reason} = error -> error
    end
  end

  @doc "Validate the tool-call grouping invariants of a chronological transcript."
  @spec validate_transcript([Message.t()]) :: :ok | {:error, term()}
  def validate_transcript(messages) when is_list(messages) do
    with :ok <- validate_messages(messages) do
      validate_groups(messages)
    end
  end

  def validate_transcript(other), do: {:error, {:invalid_transcript, other}}

  @doc "True when a chronological list is a structurally valid request transcript."
  @spec valid_transcript?([Message.t()]) :: boolean()
  def valid_transcript?(messages), do: validate_transcript(messages) == :ok

  @doc "Stable prefix used for a persisted summary-shaped user message."
  @spec summary_prefix() :: String.t()
  def summary_prefix, do: @summary_prefix

  @doc "Unique provider continuation namespace for one compaction attempt."
  @spec companion_id(String.t()) :: String.t()
  def companion_id(session_id) when is_binary(session_id) do
    digest = :crypto.hash(:sha256, session_id) |> Base.url_encode64(padding: false)
    attempt = System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)
    "@compact:" <> digest <> ":" <> attempt
  end

  defp registry_or_builtin(model, window, anchored?) do
    case Registry.threshold(model) do
      {:ok, value, source} -> normalize_threshold(value, window, source)
      :missing -> builtin_threshold_for_window(model, window, anchored?)
      {:error, _reason} = error -> error
    end
  end

  defp builtin_threshold_for_window(model, window, anchored?) do
    catalog_limit = catalog_limit(model, window)
    ratio_limit = ratio_limit(window, anchored?)

    case Enum.filter([catalog_limit, ratio_limit], &positive_integer?/1) do
      [] -> :none
      limits -> {:ok, Enum.min(limits), :builtin}
    end
  end

  @doc false
  @spec builtin_threshold(Catalyst.Model.t() | nil, boolean()) ::
          {:ok, pos_integer(), :builtin} | :none
  def builtin_threshold(model, anchored?) do
    window = effective_window(model)
    catalog_limit = catalog_limit(model, window)
    ratio_limit = ratio_limit(window, anchored?)

    case Enum.filter([catalog_limit, ratio_limit], &positive_integer?/1) do
      [] -> :none
      limits -> {:ok, Enum.min(limits), :builtin}
    end
  end

  defp session_threshold(context) do
    opts = Map.get(context, :opts, []) || []

    cond do
      Map.has_key?(context, :context_threshold) ->
        {:ok, context.context_threshold}

      is_list(opts) and Keyword.has_key?(opts, :context_threshold) ->
        {:ok, Keyword.fetch!(opts, :context_threshold)}

      true ->
        :missing
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
    protected_count = min(length(units), protected_unit_count(units, context))

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
    summary = summarize(removed, context)
    original = removed ++ kept

    case fit_candidate(summary, kept, protected_count, before, target, threshold, context) do
      {:ok, replacement, accepted_summary, after_tokens} ->
        {:ok,
         %Compaction{
           replacement: replacement,
           summary: accepted_summary,
           replaced_count: replaced_count(original, replacement),
           tokens_before: before,
           tokens_after: after_tokens,
           policy: __MODULE__
         }}

      {:error, _reason} ->
        # A failed/oversized summary is not fatal.  Retry the same deterministic
        # whole-unit tightening without it before declaring the suffix irreducible.
        case fit_candidate(nil, kept, protected_count, before, target, threshold, context) do
          {:ok, replacement, nil, after_tokens} ->
            {:ok,
             %Compaction{
               replacement: replacement,
               summary: nil,
               replaced_count: replaced_count(original, replacement),
               tokens_before: before,
               tokens_after: after_tokens,
               policy: __MODULE__
             }}

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
    after_tokens = estimate_replacement(replacement, context)
    valid? = after_tokens < before and valid_transcript?(replacement)

    cond do
      valid? and after_tokens <= target ->
        {:ok, replacement, summary, after_tokens}

      not is_nil(summary) ->
        {:error, :summary_missed_target}

      kept == protected and valid? and after_tokens < threshold ->
        {:ok, replacement, nil, after_tokens}

      kept == protected ->
        {:error, :irreducible_context}

      true ->
        [_drop | tighter] = message_units(kept)

        do_fit_candidate(
          summary,
          List.flatten(tighter),
          protected,
          before,
          target,
          threshold,
          context
        )
    end
  end

  defp protected_suffix(messages, count) do
    messages
    |> message_units()
    |> Enum.take(-count)
    |> List.flatten()
  end

  defp estimate_replacement(messages, context) do
    case Map.get(context, :estimate_replacement) do
      fun when is_function(fun, 1) -> fun.(messages)
      fun when is_function(fun, 2) -> fun.(messages, context)
      _none -> estimate_messages(messages, context)
    end
  end

  defp estimate_messages(messages, context) do
    base = Map.get(context, :base_tokens, 0)

    bytes =
      messages
      |> Enum.map(&render_message/1)
      |> IO.iodata_to_binary()
      |> byte_size()

    base + div(bytes + 3, 4)
  end

  defp summarize([], _context), do: nil

  defp summarize(removed, context) do
    task = Tasks.async(fn -> run_summarizer(removed, context) end)
    timeout = Map.get(context, :compaction_timeout, policy_timeout())

    case Tasks.await(task, timeout) do
      {:ok, {:ok, text}} -> summary_message(text)
      {:ok, text} when is_binary(text) -> summary_message(text)
      _failure -> nil
    end
  end

  defp run_summarizer(removed, context) do
    case Map.get(context, :summary_fun) do
      fun when is_function(fun, 2) -> normalize_summary(fun.(removed, context))
      fun when is_function(fun, 1) -> normalize_summary(fun.(removed))
      _none -> provider_summary(removed, context)
    end
  end

  defp provider_summary(removed, context) do
    provider = Map.get(context, :provider)
    model = Map.get(context, :model)

    case is_atom(provider) and not is_nil(provider) and function_exported?(provider, :stream, 4) and
           not is_nil(model) do
      true -> stream_summary(provider, model, removed, context)
      false -> {:error, :no_summarizer}
    end
  end

  defp stream_summary(provider, model, removed, context) do
    session_id = companion_id(to_string(Map.get(context, :session_id, "unknown")))
    source = removed |> render_messages() |> bound_summary_source(model)

    with :ok <- register_resource(context, provider, session_id) do
      try do
        with {:ok, prompt} <- compaction_prompt(model, context) do
          llm_context = %LLMContext{
            system_prompt: prompt,
            messages: [Message.user(source)],
            tools: []
          }

          opts = context |> Map.get(:opts, []) |> Keyword.put(:session_id, session_id)

          case provider.stream(model, llm_context, opts, fn _event -> :ok end) do
            {:ok, %Message.Assistant{stop_reason: reason} = assistant}
            when reason in [:stop, :length] ->
              normalize_summary(Content.text_of(assistant.content))

            {:ok, _invalid} ->
              {:error, :invalid_summary}

            {:error, _reason} = error ->
              error
          end
        end
      after
        cleanup_provider(provider, session_id)
      end
    end
  end

  defp compaction_prompt(model, context) do
    request =
      struct(Catalyst.Prompt.Request,
        purpose: :compaction,
        model: model,
        cwd: Map.get(context, :cwd),
        session_id: Map.get(context, :session_id),
        opts: Map.get(context, :opts, [])
      )

    case Catalyst.Prompt.resolve_bounded(request) do
      {:ok, resolution} -> {:ok, resolution.text}
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:compaction_prompt_exception, Exception.message(error)}}
  end

  defp register_resource(context, provider, session_id) do
    resource = %{provider: provider, session_id: session_id}

    case Map.get(context, :register_resource) do
      fun when is_function(fun, 1) -> normalize_resource_registration(fun.(resource))
      _none -> :ok
    end
  end

  defp normalize_resource_registration({:error, _reason} = error), do: error
  defp normalize_resource_registration(_result), do: :ok

  defp cleanup_provider(provider, session_id) do
    case function_exported?(provider, :cleanup_session, 1) do
      true -> provider.cleanup_session(session_id)
      false -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp normalize_summary({:ok, text}), do: normalize_summary(text)

  defp normalize_summary(text) when is_binary(text) do
    text = Truncate.scrub_utf8(text)

    case byte_size(text) > @summary_result_limit do
      true -> {:error, :summary_too_large}
      false -> normalize_trimmed_summary(String.trim(text))
    end
  end

  defp normalize_summary(_invalid), do: {:error, :invalid_summary}

  defp normalize_trimmed_summary(""), do: {:error, :blank_summary}
  defp normalize_trimmed_summary(text), do: {:ok, text}

  defp summary_message({:ok, text}), do: summary_message(text)

  defp summary_message(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      value -> Message.user(@summary_prefix <> value)
    end
  end

  defp summary_message(_invalid), do: nil

  defp bound_summary_source(source, model) do
    max_bytes =
      case effective_window(model) do
        {:ok, window} -> max(1, min(200_000, floor(window * 0.50) * 4))
        :error -> 120_000
      end

    elem(Truncate.head(source, max_bytes: max_bytes), 0)
  end

  defp render_messages(messages), do: Enum.map_join(messages, "\n\n", &render_message/1)

  defp render_message(%Message.User{content: content}),
    do: "User: " <> render_content(content)

  defp render_message(%Message.Assistant{content: content}),
    do: "Assistant: " <> render_content(content)

  defp render_message(%Message.ToolResult{tool_name: name, content: content}) do
    text =
      content |> render_content() |> Truncate.scrub_utf8() |> String.slice(0, @tool_result_limit)

    "Tool result (#{name}): " <> text
  end

  defp render_message(other), do: inspect(other, limit: 20, printable_limit: 2_000)

  defp render_content(content) do
    Enum.map_join(List.wrap(content), "", fn
      %Content.Text{text: text} ->
        text

      %Content.Thinking{thinking: thinking} ->
        "[thinking: #{thinking}]"

      %Content.Image{mime_type: mime} ->
        "[image: #{mime}]"

      %Content.ToolCall{name: name, arguments: args} ->
        "[tool call: #{name} #{inspect(args, limit: 20, printable_limit: 1_000)}]"

      other ->
        inspect(other, limit: 10, printable_limit: 500)
    end)
  end

  # Each assistant tool-call and its complete immediately-following result set
  # is one indivisible unit.  Ordinary messages are single-message units.
  defp message_units(messages), do: do_units(messages, []) |> Enum.reverse()

  defp do_units([], acc), do: acc

  defp do_units([%Message.Assistant{} = assistant | rest], acc) do
    calls = Message.tool_calls(assistant)

    case calls do
      [] ->
        do_units(rest, [[assistant] | acc])

      _ ->
        {results, tail} = Enum.split_while(rest, &match?(%Message.ToolResult{}, &1))
        do_units(tail, [[assistant | results] | acc])
    end
  end

  defp do_units([message | rest], acc), do: do_units(rest, [[message] | acc])

  defp validate_groups(messages), do: do_validate_groups(messages)

  defp validate_messages(messages) do
    case Enum.find(messages, &(not message?(&1))) do
      nil -> :ok
      invalid -> {:error, {:invalid_transcript_message, invalid}}
    end
  end

  defp message?(%Message.User{}), do: true
  defp message?(%Message.Assistant{}), do: true
  defp message?(%Message.ToolResult{}), do: true
  defp message?(_other), do: false

  defp do_validate_groups([]), do: :ok

  defp do_validate_groups([%Message.ToolResult{} | _rest]),
    do: {:error, :orphan_tool_result}

  defp do_validate_groups([%Message.Assistant{} = assistant | rest]) do
    calls = Message.tool_calls(assistant)

    case calls do
      [] -> do_validate_groups(rest)
      _ -> validate_assistant_group(calls, rest)
    end
  end

  defp do_validate_groups([_message | rest]), do: do_validate_groups(rest)

  defp validate_assistant_group(calls, rest) do
    {results, tail} = Enum.split_while(rest, &match?(%Message.ToolResult{}, &1))
    expected = calls |> Enum.map(& &1.id) |> MapSet.new()
    actual = results |> Enum.map(& &1.tool_call_id) |> MapSet.new()

    case expected == actual and length(calls) == MapSet.size(expected) and
           length(results) == MapSet.size(actual) do
      true -> do_validate_groups(tail)
      false -> {:error, {:invalid_tool_result_group, expected, actual}}
    end
  end

  defp protected_unit_count(units, context) do
    case Map.get(context, :protected_units) do
      count when is_integer(count) and count > 0 -> count
      _automatic -> automatic_protected_unit_count(units)
    end
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

  defp replaced_count(original, replacement) do
    retained = common_suffix_length(Enum.reverse(original), Enum.reverse(replacement), 0)
    max(1, length(original) - retained)
  end

  defp common_suffix_length([message | original], [message | replacement], count),
    do: common_suffix_length(original, replacement, count + 1)

  defp common_suffix_length(_original, _replacement, count), do: count

  defp policy_timeout,
    do: Application.get_env(:catalyst, :context_policy_timeout, @default_policy_timeout)

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
