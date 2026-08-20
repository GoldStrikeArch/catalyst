defmodule Catalyst.Session.RunContext do
  @moduledoc """
  Worker-side constructor for one immutable run configuration epoch.

  Session.Server passes a snapshot into a supervised run task. Prompt-policy and
  workflow resolution happen here, never in a GenServer callback. The resulting
  prompt/workflow/model metadata is pinned for the run and reported separately
  for diagnostics; it is not reused as future configuration.
  """

  alias Catalyst.{Model, Prompt, Workflow}
  alias Catalyst.Prompt.{Request, Resolution}
  alias Catalyst.Session.RunConfig

  @type t :: %{
          context: map(),
          config: RunConfig.t(),
          metadata: map()
        }

  @doc "Resolve one run from an immutable session-state snapshot."
  @spec build(map(), pid(), reference(), module()) :: {:ok, t()} | {:error, term()}
  def build(state, server, run_ref, provider) do
    with {:ok, workflow} <- Workflow.resolve(state.opts || []) do
      build_with(state, server, run_ref, provider, workflow)
    end
  end

  @doc "Resolve one run, including conditional provider resolution, inside its worker."
  @spec build(map(), pid(), reference()) :: {:ok, t()} | {:error, term()}
  def build(state, server, run_ref) do
    with {:ok, workflow} <- Workflow.resolve(state.opts || []),
         {:ok, provider} <- resolve_provider(state, workflow) do
      build_with(state, server, run_ref, provider, workflow)
    end
  end

  defp build_with(state, server, run_ref, provider, workflow) do
    with {:ok, base} <- RunConfig.build_base(state, server, run_ref, provider),
         {:ok, model, catalog} <- resolve_model(state.model),
         {:ok, prompt} <- resolve_prompt(state, model) do
      config =
        base
        |> Map.put(:model, model)
        |> Map.put(:loop, workflow.module)
        |> Map.put(:workflow, workflow)
        |> Map.put(:prompt_override, Map.get(state, :system_prompt))

      metadata = %{
        prompt: prompt_metadata(prompt),
        workflow: workflow,
        context: model_metadata(model),
        context_status: nil
      }

      config =
        config
        |> Map.put(:prompt_cache, %{model_key(model) => prompt})
        |> Map.put(:active_model_key, model_key(model))
        |> Map.put(:active_model_identity, model_identity(model))
        |> Map.put(:active_prompt, prompt.text)
        |> Map.put(:run_metadata, metadata)
        |> Map.put(:catalog_snapshot, catalog)

      {:ok,
       %{
         context: %{system_prompt: prompt.text, messages: Enum.reverse(state.messages)},
         config: config,
         metadata: metadata
       }}
    end
  end

  defp resolve_provider(state, workflow) do
    case Workflow.provider_required?(workflow.module) do
      true -> RunConfig.resolve_provider(state)
      false -> {:ok, nil}
    end
  end

  @doc "Resolve a run/prewarm system prompt through a bounded supervised policy call."
  @spec resolve_prompt(map(), Model.t() | nil) :: {:ok, Resolution.t()} | {:error, term()}
  def resolve_prompt(state, model \\ nil) do
    request = %Request{
      purpose: :system,
      model: model || Map.get(state, :model),
      cwd: Map.get(state, :cwd),
      session_id: Map.get(state, :id),
      override: Map.get(state, :system_prompt),
      opts: Map.get(state, :opts, []) || []
    }

    Prompt.resolve_bounded(request)
  end

  @doc """
  Reconcile a hook-selected model and system prompt before one request.

  Catalog metadata comes from the run-start snapshot and model prompt
  resolutions are cached for the run. An explicit hook prompt remains a
  separate provenance layer and is never inserted into the model cache.
  Hook overrides are tracked on the config and reapplied after model
  reconciliation so a model-only epoch cannot clobber them.

  Contract: a hook `system_prompt` equal to the currently active prompt is
  treated as "no hook override" — the context always carries the active
  prompt back into the next turn, so equality is indistinguishable from an
  untouched context. A hook that wants a sticky pin must supply text that
  differs from the active resolution (it is then retained across model-only
  epochs with `{:hook, :prepare_next_turn}` provenance).
  """
  @spec reconcile_request(map(), map()) :: {:ok, map(), map()} | {:error, term()}
  def reconcile_request(context, config) when is_map(context) and is_map(config) do
    {context, config, prompt_action} = capture_hook_prompt(context, config)

    with {:ok, context, config} <- reconcile_model(context, config),
         {:ok, context, config} <- apply_hook_prompt(context, config, prompt_action) do
      {:ok, context, config}
    end
  end

  @doc """
  Resolve the effective model a run started now would use.

  For catalog-backed APIs (OpenAI Codex) this refreshes context-window
  metadata from the current catalog snapshot — the same pre-request refresh
  `build/4` performs. The single resolver behind preview/panel call sites;
  non-catalog models (and `nil`) pass through unchanged.
  """
  @spec effective_model(Model.t() | nil) :: Model.t() | nil
  def effective_model(%Model{} = model) do
    # resolve_model/1 cannot error on a %Model{} input; the type checker
    # rejects an unreachable {:error, _} fallback clause here.
    {:ok, resolved, _catalog} = resolve_model(model)
    resolved
  end

  def effective_model(model), do: model

  @doc "Resolve model context metadata from the immutable run-start catalog snapshot."
  @spec resolve_epoch_model(Model.t() | nil, map() | nil) ::
          {:ok, Model.t() | nil} | {:error, term()}
  def resolve_epoch_model(nil, _snapshot), do: {:ok, nil}

  def resolve_epoch_model(%Model{api: "openai-codex-responses"} = model, snapshot) do
    case model.context_window_source do
      :session -> {:ok, model}
      _refreshable -> {:ok, merge_catalog_metadata(model, snapshot_entry(snapshot, model.id))}
    end
  end

  def resolve_epoch_model(%Model{} = model, _snapshot), do: {:ok, model}
  def resolve_epoch_model(other, _snapshot), do: {:error, {:invalid_model, other}}

  @doc "Project resolved model limits into run diagnostics."
  @spec model_metadata(Model.t() | nil) :: map() | nil
  def model_metadata(nil), do: nil

  def model_metadata(%Model{} = model) do
    %{
      model_id: model.id,
      api: model.api,
      provider: model.provider,
      context_window: model.context_window,
      max_context_window: model.max_context_window,
      effective_context_window_percent: model.effective_context_window_percent,
      auto_compact_token_limit: model.auto_compact_token_limit,
      context_window_source: model.context_window_source
    }
  end

  defp reconcile_model(context, config) do
    model = Map.get(config, :model)
    requested_identity = model_identity(model)
    active_identity = Map.get(config, :active_model_identity, requested_identity)

    case requested_identity == active_identity do
      true ->
        {:ok, context, config}

      false ->
        with {:ok, model} <- resolve_epoch_model(model, Map.get(config, :catalog_snapshot)),
             {:ok, resolution, prompt_cache} <- cached_prompt(config, model) do
          config =
            config
            |> Map.put(:model, model)
            |> Map.put(:prompt_cache, prompt_cache)
            |> update_epoch(resolution)

          {:ok, Map.put(context, :system_prompt, resolution.text), config}
        end
    end
  end

  # Capture hook intent before model reconciliation so a later model-only epoch
  # cannot treat an already-applied override as "unchanged" and drop it.
  defp capture_hook_prompt(context, config) do
    case Map.fetch(context, :system_prompt) do
      :error ->
        prompt = Map.get(config, :active_prompt)
        {Map.put(context, :system_prompt, prompt), config, :preserve}

      {:ok, nil} ->
        {context, Map.put(config, :hook_prompt_override, nil), :clear}

      {:ok, prompt} when is_binary(prompt) ->
        cond do
          Map.get(config, :hook_prompt_override) == prompt ->
            {context, config, :reapply}

          prompt != Map.get(config, :active_prompt) ->
            {context, Map.put(config, :hook_prompt_override, prompt), :set}

          true ->
            {context, config, :none}
        end

      {:ok, other} ->
        {context, config, {:invalid, other}}
    end
  end

  defp apply_hook_prompt(context, config, :none), do: {:ok, context, config}
  defp apply_hook_prompt(context, config, :preserve), do: reapply_hook_override(context, config)
  defp apply_hook_prompt(context, config, :reapply), do: reapply_hook_override(context, config)

  defp apply_hook_prompt(context, config, :set),
    do: install_hook_prompt(context, config, Map.fetch!(config, :hook_prompt_override))

  defp apply_hook_prompt(context, config, :clear) do
    with {:ok, resolution, prompt_cache} <- cached_prompt(config, Map.get(config, :model)) do
      config =
        config
        |> Map.put(:prompt_cache, prompt_cache)
        |> Map.put(:hook_prompt_override, nil)
        |> update_epoch(resolution)

      {:ok, Map.put(context, :system_prompt, resolution.text), config}
    end
  end

  defp apply_hook_prompt(_context, _config, {:invalid, prompt}),
    do: {:error, {:invalid_hook_system_prompt, prompt}}

  defp reapply_hook_override(context, config) do
    case Map.get(config, :hook_prompt_override) do
      prompt when is_binary(prompt) ->
        case Map.get(context, :system_prompt) do
          # Model reconciliation left the override in place — no epoch churn.
          ^prompt -> {:ok, context, config}
          _overwritten -> install_hook_prompt(context, config, prompt)
        end

      _none ->
        {:ok, context, config}
    end
  end

  defp install_hook_prompt(context, config, prompt) when is_binary(prompt) do
    resolution = Resolution.new(prompt, [{:hook, :prepare_next_turn}])

    # Prompt owns resolution validation; this keeps hook prompts on the same
    # (stricter) contract as policy resolutions: UTF-8 scrub + first invalid
    # source in the provenance error.
    case Prompt.normalize_resolution(resolution) do
      {:ok, resolution} ->
        config =
          config
          |> Map.put(:hook_prompt_override, resolution.text)
          |> update_epoch(resolution)

        {:ok, Map.put(context, :system_prompt, resolution.text), config}

      {:error, reason} ->
        {:error, {:invalid_hook_system_prompt, reason}}
    end
  end

  defp cached_prompt(config, model) do
    key = model_key(model)
    cache = Map.get(config, :prompt_cache, %{})

    case Map.fetch(cache, key) do
      {:ok, resolution} ->
        {:ok, resolution, cache}

      :error ->
        with {:ok, resolution} <- resolve_prompt(prompt_state(config), model) do
          {:ok, resolution, Map.put(cache, key, resolution)}
        end
    end
  end

  defp prompt_state(config) do
    %{
      id: config |> Map.get(:opts, []) |> Keyword.get(:session_id),
      cwd: Map.get(config, :cwd),
      system_prompt: Map.get(config, :prompt_override),
      opts: Map.get(config, :opts, [])
    }
  end

  defp update_epoch(config, resolution) do
    metadata =
      config
      |> Map.get(:run_metadata, %{})
      |> Map.put(:prompt, prompt_metadata(resolution))
      |> Map.put(:context, model_metadata(Map.get(config, :model)))
      |> Map.put(:context_status, nil)

    report_metadata(config, metadata)

    config
    |> Map.put(:active_model_key, model_key(Map.get(config, :model)))
    |> Map.put(:active_model_identity, model_identity(Map.get(config, :model)))
    |> Map.put(:active_prompt, resolution.text)
    |> Map.put(:run_metadata, metadata)
  end

  defp report_metadata(config, metadata) do
    case Map.get(config, :report_metadata) do
      fun when is_function(fun, 1) -> fun.(metadata)
      _none -> :ok
    end
  end

  defp resolve_model(nil), do: {:ok, nil, nil}

  defp resolve_model(%Model{} = model) do
    case model.api do
      "openai-codex-responses" -> resolve_codex_model(model)
      _other -> {:ok, model, nil}
    end
  end

  defp resolve_model(other), do: {:error, {:invalid_model, other}}

  defp resolve_codex_model(model) do
    snapshot = Catalyst.LLM.OpenAICodex.catalog_snapshot(model.id)

    with {:ok, resolved} <- resolve_epoch_model(model, snapshot) do
      {:ok, resolved, snapshot}
    end
  end

  defp merge_catalog_metadata(%Model{} = model, entry) do
    catalog_window = positive(entry.context_window) || positive(entry.max_context_window)
    persisted_window = positive(model.context_window) || positive(model.max_context_window)

    %Model{
      model
      | context_window: catalog_window || persisted_window || 272_000,
        max_context_window: positive(entry.max_context_window) || model.max_context_window,
        effective_context_window_percent:
          entry.effective_context_window_percent || model.effective_context_window_percent,
        auto_compact_token_limit:
          positive(entry.auto_compact_token_limit) || model.auto_compact_token_limit,
        context_window_source: context_window_source(model, catalog_window, persisted_window)
    }
  end

  defp context_window_source(_model, catalog_window, _persisted_window)
       when is_integer(catalog_window),
       do: :catalog

  defp context_window_source(%Model{context_window_source: :fallback}, nil, persisted_window)
       when is_integer(persisted_window),
       do: :fallback

  defp context_window_source(_model, nil, persisted_window) when is_integer(persisted_window),
    do: :persisted

  defp context_window_source(_model, nil, nil), do: :fallback

  defp prompt_metadata(prompt) do
    %{text: prompt.text, digest: prompt.digest, sources: prompt.sources}
  end

  defp snapshot_entry(%{models: models}, id) when is_list(models) do
    Enum.find(models, &(&1.id == id)) ||
      Catalyst.LLM.OpenAICodex.Catalog.normalize(%{id: id})
  end

  defp snapshot_entry(_snapshot, id),
    do: Catalyst.LLM.OpenAICodex.Catalog.normalize(%{id: id})

  defp model_key(nil), do: :default
  defp model_key(model), do: {model.id, model.api}

  defp model_identity(nil), do: :default
  defp model_identity(model), do: {model.id, model.api, model.provider}

  defp positive(value), do: Model.positive_int(value)
end
