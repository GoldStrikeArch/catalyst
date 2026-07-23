defmodule Catalyst.Context.Guard do
  @moduledoc """
  Request-boundary context accounting and staged persistent compaction.

  Conforming workflows call `prepare_request/4` before every ordinary provider
  request and before emitting turn/message start events.  The transform hook is
  run once normally and exactly once more when a compaction candidate is staged.
  A rejected candidate never changes or persists the chronological transcript.
  """

  alias Catalyst.Agent.Event
  alias Catalyst.{Hooks, Tasks}
  alias Catalyst.Context.{Compaction, Registry, Tokens, Transcript, Window}
  alias Catalyst.LLM.Context, as: LLMContext
  alias Catalyst.Tools.Registry, as: ToolRegistry

  @default_timeout 30_000
  @compaction_timeout_ratio 0.8

  @typedoc "Successful guarded request assembly."
  @type prepared :: %{
          context: map(),
          llm_context: LLMContext.t(),
          status: Event.ContextStatus.t(),
          compacted?: boolean()
        }

  @doc """
  Build and guard one exact request.

  `context` owns the chronological `:messages` and resolved `:system_prompt`;
  `config` owns model/provider/tools/provider opts; `emit` receives transient or
  durable context events; `guard_opts` may carry run-scoped resource callbacks.
  """
  @spec prepare_request(map(), map(), (struct() -> any()), keyword() | map()) ::
          {:ok, prepared()} | {:error, term()}
  def prepare_request(context, config, emit, guard_opts \\ [])
      when is_map(context) and is_map(config) and is_function(emit, 1) do
    with {:ok, llm_context} <- build_llm_context(context, config),
         {:ok, estimate} <- estimate(config, llm_context),
         {:ok, policy, policy_source} <- Registry.policy(),
         {:ok, threshold, threshold_source} <-
           resolve_threshold(policy, policy_source, config, estimate, guard_opts) do
      status = status_event(estimate, threshold, threshold_source)
      emit.(status)

      case compaction_required?(threshold, estimate.tokens) do
        false ->
          {:ok, %{context: context, llm_context: llm_context, status: status, compacted?: false}}

        true ->
          compact_request(
            policy,
            context,
            config,
            llm_context,
            %{estimate: estimate, threshold: threshold, source: threshold_source},
            emit,
            guard_opts
          )
      end
    end
  end

  @doc "Build the transformed provider context without performing accounting."
  @spec build_llm_context(map(), map()) :: {:ok, LLMContext.t()} | {:error, term()}
  def build_llm_context(context, config) do
    with {:ok, messages} <- transform_messages(context, config) do
      convert = Map.get(config, :convert_to_llm) || (&Function.identity/1)
      tools = provider_tools(config)

      case convert.(messages) do
        converted when is_list(converted) ->
          {:ok,
           %LLMContext{
             system_prompt: Map.get(context, :system_prompt),
             messages: converted,
             tools: tools
           }}

        invalid ->
          {:error, {:invalid_llm_context, invalid}}
      end
    end
  rescue
    error -> {:error, {:context_transform_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:context_transform_exit, {kind, reason}}}
  end

  defp transform_messages(context, config) do
    messages = Map.get(context, :messages, [])
    hook_context = %{config: config}

    case Map.get(config, :hook_snapshot) do
      snapshot when is_map(snapshot) ->
        Hooks.transform_context(messages, hook_context, snapshot)

      _missing ->
        with {:ok, snapshot} <- Hooks.capture_snapshot([:transform_context]) do
          Hooks.transform_context(messages, hook_context, snapshot)
        end
    end
  end

  defp provider_tools(config) do
    case Map.get(config, :tool_index) do
      index when is_map(index) -> ToolRegistry.to_provider_tools(index)
      _missing -> ToolRegistry.to_provider_tools(Map.get(config, :tools, []))
    end
  end

  defp resolve_threshold(policy, source, config, estimate, guard_opts) do
    model = Map.get(config, :model)

    policy_context =
      guard_opts
      |> to_map()
      |> Map.merge(%{
        opts: Map.get(config, :opts, []),
        provider: Map.get(config, :provider),
        anchored: estimate.anchored,
        estimate: estimate
      })

    case policy do
      Window ->
        case Window.threshold_with_source(model, policy_context) do
          # `{:ok, :none, source}` means a source explicitly disabled
          # compaction and keeps that source's provenance; a bare `:none`
          # means no source resolved anything — no window and no catalog
          # limit exist, so the request is tagged `:unlimited` instead of
          # inheriting the policy's provenance.
          {:ok, value, threshold_source} -> {:ok, value, threshold_source}
          :none -> {:ok, :none, :unlimited}
          {:error, _reason} = error -> error
        end

      custom ->
        case call_policy(custom, :threshold, [model, policy_context]) do
          {:ok, {:ok, value}} when is_integer(value) and value > 0 ->
            {:ok, value, source}

          {:ok, :none} ->
            {:ok, :none, source}

          {:ok, {:error, reason}} ->
            {:error, reason}

          {:ok, invalid} ->
            {:error, {:invalid_context_policy_return, custom, :threshold, invalid}}

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp compact_request(
         policy,
         context,
         config,
         llm_context,
         %{estimate: estimate, threshold: threshold, source: threshold_source},
         emit,
         guard_opts
       ) do
    guard_opts = to_map(guard_opts)

    compaction_context =
      guard_opts
      |> Map.put(:compaction_timeout, compaction_timeout(guard_opts))
      |> Map.merge(%{
        model: Map.get(config, :model),
        provider: Map.get(config, :provider),
        opts: Map.get(config, :opts, []),
        cwd: Map.get(config, :cwd),
        session_id: session_id(config),
        threshold: threshold,
        tokens_before: estimate.tokens,
        base_tokens: base_tokens(llm_context),
        estimate_replacement: replacement_estimator(llm_context, config)
      })

    with {:ok, %Compaction{} = candidate} <-
           call_compact(policy, Map.get(context, :messages, []), compaction_context),
         :ok <- validate_candidate(candidate, context),
         staged_context = Map.put(context, :messages, candidate.replacement),
         {:ok, staged_llm_context} <- build_llm_context(staged_context, config),
         {:ok, staged_estimate} <- estimate(config, staged_llm_context),
         :ok <- validate_progress(estimate.tokens, staged_estimate.tokens, threshold),
         event = %Event.ContextCompacted{
           replacement: candidate.replacement,
           summary: candidate.summary,
           replaced_count: replaced_count(Map.get(context, :messages, []), candidate.replacement),
           tokens_before: estimate.tokens,
           tokens_after: staged_estimate.tokens,
           policy: policy
         },
         :ok <- persist_durable(guard_opts, emit, event) do
      status = status_event(staged_estimate, threshold, threshold_source)
      emit.(status)

      {:ok,
       %{
         context: staged_context,
         llm_context: staged_llm_context,
         status: status,
         compacted?: true
       }}
    else
      {:ok, invalid} -> {:error, {:invalid_context_policy_return, policy, :compact, invalid}}
      {:error, _reason} = error -> error
    end
  end

  # The durable replacement must be recorded before the provider sees the
  # compacted history. A run-scoped :persist_event callback folds and persists
  # it synchronously; without one (tests, sovereign workflows) the plain emit
  # preserves the previous asynchronous behavior.
  defp persist_durable(guard_opts, emit, event) do
    case Map.get(guard_opts, :persist_event) do
      persist when is_function(persist, 1) ->
        case persist.(event) do
          :ok -> :ok
          {:error, reason} -> {:error, {:compaction_not_persisted, reason}}
          invalid -> {:error, {:compaction_not_persisted, invalid}}
        end

      _missing ->
        emit.(event)
        :ok
    end
  end

  defp call_compact(policy, messages, context) do
    case call_policy(policy, :compact, [messages, context]) do
      {:ok, {:ok, _candidate} = result} -> result
      {:ok, {:error, _reason} = error} -> error
      {:ok, invalid} -> {:ok, invalid}
      {:error, _reason} = error -> error
    end
  end

  defp call_policy(module, callback, args) do
    task = Tasks.async(fn -> apply(module, callback, args) end)

    case Tasks.await(task, policy_timeout()) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, {:context_policy_exit, module, callback, reason}}
      :timeout -> {:error, {:context_policy_timeout, module, callback}}
    end
  end

  defp validate_candidate(%Compaction{} = candidate, context) do
    original = Map.get(context, :messages, [])

    removed_count =
      case is_list(candidate.replacement) do
        true -> replaced_count(original, candidate.replacement)
        false -> nil
      end

    cond do
      not is_list(candidate.replacement) ->
        {:error, {:invalid_compaction_replacement, candidate.replacement}}

      # Store refuses to fold an empty replacement, so accepting one here would
      # empty the live transcript while a restart resurrects the old history.
      candidate.replacement == [] ->
        {:error, {:invalid_compaction_replacement, []}}

      candidate.replacement == original ->
        {:error, :context_compaction_no_progress}

      is_integer(removed_count) and removed_count < 1 ->
        {:error, :context_compaction_no_progress}

      not is_nil(candidate.summary) and not match?(%Catalyst.Message.User{}, candidate.summary) ->
        {:error, {:invalid_compaction_summary, candidate.summary}}

      not is_nil(candidate.summary) and candidate.summary not in candidate.replacement ->
        {:error, :compaction_summary_not_in_replacement}

      true ->
        Transcript.validate_transcript(candidate.replacement)
    end
  end

  defp validate_progress(before, after_tokens, threshold)
       when after_tokens < before and after_tokens < threshold,
       do: :ok

  defp validate_progress(_before, after_tokens, threshold),
    do: {:error, {:context_compaction_still_oversized, after_tokens, threshold}}

  # Unlike Window's user-facing accounting, this may legitimately be zero:
  # a zero count is how `validate_candidate/2` detects no progress.
  defp replaced_count(original, replacement),
    do: length(original) - Transcript.common_suffix_length(original, replacement)

  # The estimator returns the tagged `Tokens.estimate_tokens/3` result as-is;
  # the policy treats `{:error, reason}` as an unfit candidate.
  defp replacement_estimator(llm_context, config) do
    fn messages ->
      replacement = %{llm_context | messages: messages}
      Tokens.estimate_tokens(Map.get(config, :model), replacement, token_opts(config))
    end
  end

  defp base_tokens(llm_context) do
    empty = %{llm_context | messages: []}

    case Tokens.estimate_tokens(nil, empty, []) do
      {:ok, value} -> value
      {:error, _reason} -> 0
    end
  end

  defp estimate(config, llm_context) do
    Tokens.estimate(Map.get(config, :model), llm_context, token_opts(config))
  end

  defp token_opts(config) do
    config
    |> Map.get(:opts, [])
    |> Keyword.put(:provider, Map.get(config, :provider))
  end

  defp status_event(estimate, threshold, threshold_source) do
    %Event.ContextStatus{
      used_tokens: estimate.tokens,
      threshold: nil_if_none(threshold),
      threshold_source: threshold_source,
      anchored: estimate.anchored,
      estimate_source: estimate.source,
      context_digest: estimate.context_digest
    }
  end

  defp compaction_required?(:none, _used), do: false
  defp compaction_required?(threshold, used), do: used >= threshold

  defp nil_if_none(:none), do: nil
  defp nil_if_none(value), do: value

  defp session_id(config),
    do: config |> Map.get(:opts, []) |> Keyword.get(:session_id, "unknown")

  defp compaction_timeout(opts) do
    default = default_compaction_timeout(policy_timeout())

    case Map.get(opts, :compaction_timeout) do
      timeout when is_integer(timeout) and timeout >= 0 -> min(timeout, default)
      _missing_or_invalid -> default
    end
  end

  defp default_compaction_timeout(timeout) when is_integer(timeout) and timeout > 1,
    do: max(1, floor(timeout * @compaction_timeout_ratio))

  defp default_compaction_timeout(1), do: 0
  defp default_compaction_timeout(_invalid_or_infinite), do: floor(@default_timeout * 0.8)

  defp policy_timeout,
    do: Application.get_env(:catalyst, :context_policy_timeout, @default_timeout)

  defp to_map(opts) when is_list(opts), do: Map.new(opts)
  defp to_map(opts) when is_map(opts), do: opts
end
