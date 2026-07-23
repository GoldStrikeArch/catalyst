defmodule CatalystWeb.ShellLive.ExtensionsPanel do
  @moduledoc """
  Assembles the data snapshot behind the extensions panel.

  `ShellLive` calls `build/3` on navigation and after each panel action and
  assigns the result as `@ext_panel`; `CatalystWeb.Pages.ExtensionsPage` only
  renders it. The module is data-only — nothing Phoenix-aware — and would be
  core-hostable except for the `CatalystWeb.UI.Registry` reads (pages,
  commands, renderers, components), which are web-owned tables.

  Owner data comes from the bounded `Catalyst.Extensions.snapshot/0`: per-owner
  process counts are computed off-process with a deadline (degrading to
  `:unknown`), and no extension-authored code (`Processes.list/1`,
  `mod.name/0`) runs on the caller's data path.
  """

  alias Catalyst.{Extensions, Hooks, Model}
  alias Catalyst.Context.{Registry, Window}
  alias Catalyst.Extensions.Versioning
  alias Catalyst.LLM
  alias Catalyst.Prompt.Registry, as: PromptRegistry
  alias Catalyst.Session.RunContext
  alias Catalyst.Workflow.Registry, as: WorkflowRegistry
  alias CatalystWeb.UI

  @doc """
  Snapshot of the extension system for rendering: loaded/disabled extensions
  (loaded entries carry `:status`, `:purge_failures`, and a bounded
  `:process_count`) and the live contents of every registry. Cheap enough to
  rebuild on each navigation/action.
  """
  @spec build(Model.t() | nil, keyword() | map(), map()) :: map()
  def build(model \\ nil, opts \\ [], diagnostics \\ %{}) do
    snapshot = Extensions.snapshot()

    owner_by_tool =
      for %{owner: owner, tools: tools} <- snapshot.owners,
          name <- tools,
          into: %{},
          do: {name, owner}

    %{
      boot_status: snapshot.boot_status,
      dir: Extensions.dir(),
      git?: Versioning.available?(),
      loaded: snapshot.owners,
      disabled: Extensions.list_disabled(),
      tools: tool_rows(owner_by_tool),
      providers: provider_rows(),
      hooks: hook_rows(),
      prompt_runtime: PromptRegistry.runtime_entries(),
      workflow_runtime: WorkflowRegistry.runtime_entries(),
      context_runtime: Registry.runtime_entries(),
      effective: effective_rows(model, opts, diagnostics),
      pages: UI.Registry.list_pages(),
      commands: UI.Registry.list_commands(),
      renderers: UI.Registry.list_renderers(),
      components: UI.Registry.list_components()
    }
  end

  # Names and modules come straight from the tool table rows — extension
  # `name/0` is never invoked on this path (it may hang or raise).
  defp tool_rows(owner_by_tool) do
    Extensions.names()
    |> Enum.map(fn name ->
      %{name: name, module: tool_module(name), owner: Map.get(owner_by_tool, name)}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp tool_module(name) do
    case Extensions.fetch(name) do
      {:ok, module} -> module
      :error -> nil
    end
  end

  defp provider_rows do
    LLM.Registry.list()
    |> Enum.map(fn {api, cfg} -> %{api: api, module: cfg.module, name: cfg.name} end)
    |> Enum.sort_by(& &1.api)
  end

  defp hook_rows do
    for point <- Hooks.points(), entry <- Hooks.handlers(point) do
      %{point: point, id: entry.id, owner: entry.owner, priority: entry.priority}
    end
  end

  defp effective_rows(model, opts, diagnostics) do
    [effective_prompt_policy(), effective_workflow(opts)] ++
      effective_context_rows(model, opts) ++ request_context_rows(diagnostics)
  end

  defp effective_prompt_policy do
    case PromptRegistry.policy() do
      {:ok, module, source} -> effective_row("Prompt policy", module, source)
      {:error, reason} -> error_row("Prompt policy", reason)
    end
  end

  defp effective_workflow(opts) do
    case WorkflowRegistry.resolve(opts) do
      {:ok, workflow} ->
        effective_row("Workflow", {workflow.name, workflow.module}, workflow.source)

      {:error, reason} ->
        error_row("Workflow", reason)
    end
  end

  defp effective_context_rows(model, opts) do
    # The shared pre-request resolver: the panel threshold uses the same
    # effective model snapshot the next run will enforce.
    model = RunContext.effective_model(model)

    case Registry.policy() do
      {:ok, Window, source} ->
        [
          effective_row("Context policy", Window, source),
          effective_window_threshold(model, opts)
        ]

      {:ok, module, source} ->
        [
          effective_row("Context policy", module, source),
          effective_row(
            "Context threshold",
            "resolved per request by custom policy",
            source
          )
        ]

      {:error, reason} ->
        [
          error_row("Context policy", reason),
          error_row("Context threshold", {:context_policy_unavailable, reason})
        ]
    end
  end

  defp effective_window_threshold(model, opts) do
    note = "unanchored baseline; each request's ContextStatus is authoritative"

    case Window.threshold_with_source(model, %{opts: opts}) do
      {:ok, threshold, source} -> effective_row("Context threshold", threshold, source, note)
      :none -> effective_row("Context threshold", :none, :builtin, note)
      {:error, reason} -> error_row("Context threshold", reason)
    end
  end

  defp request_context_rows(%{context_status: %{} = status} = diagnostics) do
    threshold = Map.get(status, :threshold) || :none
    source = Map.get(status, :threshold_source)
    anchored = Map.get(status, :anchored, false)
    model_id = get_in(diagnostics, [:run_metadata, :context, :model_id])
    basis = if(anchored, do: "anchored", else: "estimated")
    model_note = if(is_binary(model_id), do: " for #{model_id}", else: "")

    [effective_row("Last request threshold", threshold, source, basis <> model_note)]
  end

  defp request_context_rows(_diagnostics), do: []

  defp effective_row(label, value, source, note \\ nil),
    do: %{label: label, value: value, source: source, error?: false, note: note}

  defp error_row(label, reason),
    do: %{label: label, value: reason, source: :error, error?: true, note: nil}
end
