defmodule CatalystWeb.Pages.ExtensionsPage do
  @moduledoc """
  The extensions/settings panel — registered as the `"extensions"` page in
  `CatalystWeb.UI.Registry` (a built-in page, exactly like `Pages.ChatPage`).

  Shows everything the runtime-extensibility layer knows: loaded extensions
  (owner, source file, tools/modules/processes), disabled extensions, boot
  status with safe-mode recovery, and the live contents of every registry
  (tools, LLM providers, loop hooks, pages, renderers, components, commands).
  Per-extension reload / rollback / disable buttons make the rollback system
  usable without a terminal — recovery no longer requires asking the agent.

  Render-only: data is assembled by `panel_data/0` (assigned by `ShellLive` as
  `@ext_panel` on navigation and after each action), and all button events
  (`ext_*`) are handled in `ShellLive`. Reloading this module hot-swaps the
  panel with no restart.
  """
  use CatalystWeb, :html

  alias Catalyst.{Extensions, Hooks, Model}
  alias Catalyst.Context.{Registry, Window}
  alias Catalyst.Extensions.{Processes, Versioning}
  alias Catalyst.LLM
  alias Catalyst.LLM.OpenAICodex
  alias Catalyst.Prompt.Registry, as: PromptRegistry
  alias Catalyst.Session.RunContext
  alias Catalyst.Workflow.Registry, as: WorkflowRegistry
  alias CatalystWeb.UI

  @doc """
  Snapshot of the extension system for rendering: loaded/disabled extensions
  and the live contents of every registry. Reads ETS tables and the
  `Extensions` server; cheap enough to rebuild on each navigation/action.
  """
  @spec panel_data(Catalyst.Model.t() | nil, keyword() | map(), map()) :: map()
  def panel_data(model \\ nil, opts \\ [], diagnostics \\ %{}) do
    loaded =
      Extensions.list_loaded()
      |> Enum.map(&Map.put(&1, :processes, length(Processes.list(&1.owner))))

    owner_by_tool =
      for %{owner: owner, tools: tools} <- loaded, name <- tools, into: %{}, do: {name, owner}

    %{
      boot_status: Extensions.boot_status(),
      dir: Extensions.dir(),
      git?: Versioning.available?(),
      loaded: loaded,
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

  defp tool_rows(owner_by_tool) do
    Extensions.tools()
    |> Enum.map(fn mod ->
      name = tool_name(mod)
      %{name: name, module: mod, owner: Map.get(owner_by_tool, name)}
    end)
    |> Enum.sort_by(& &1.name)
  end

  # Extension-authored name/0 reached from a render path — degrade, never crash.
  defp tool_name(mod) do
    mod.name()
  rescue
    _ -> inspect(mod)
  catch
    _, _ -> inspect(mod)
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
    model = effective_panel_model(model)

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

  # Match RunContext's pre-request catalog refresh so the panel threshold uses
  # the same effective model snapshot the next run will enforce.
  defp effective_panel_model(%Model{} = model) do
    snapshot =
      case model.api do
        "openai-codex-responses" -> OpenAICodex.catalog_snapshot(model.id)
        _other -> nil
      end

    # resolve_epoch_model/2 cannot error on a %Model{} input; the type checker
    # rejects an unreachable {:error, _} fallback clause here.
    {:ok, resolved} = RunContext.resolve_epoch_model(model, snapshot)
    resolved
  end

  defp effective_panel_model(model), do: model

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

  # ---- render -----------------------------------------------------------------

  def render(assigns) do
    assigns = assign(assigns, :diagnostic_prompt, diagnostic_prompt(assigns))

    ~H"""
    <main class="flex-1 overflow-y-auto px-4 py-6 sm:px-6">
      <div :if={@ext_panel} class="mx-auto flex max-w-5xl flex-col gap-5">
        <.panel_header panel={@ext_panel} action={@ext_action} />
        <.boot_problem_card
          :if={@ext_panel.boot_status != :ok}
          panel={@ext_panel}
          action={@ext_action}
        />
        <.loaded_extensions panel={@ext_panel} action={@ext_action} />
        <.disabled_extensions :if={@ext_panel.disabled != []} panel={@ext_panel} action={@ext_action} />
        <.effective_diagnostics panel={@ext_panel} prompt={@diagnostic_prompt} />
        <.runtime_overlays panel={@ext_panel} />
        <.registries panel={@ext_panel} />
      </div>
      <p :if={is_nil(@ext_panel)} class="mx-auto mt-24 max-w-md text-center text-sm text-neutral-500">
        Loading extension data…
      </p>
    </main>
    """
  end

  # ---- header -------------------------------------------------------------------

  defp panel_header(assigns) do
    ~H"""
    <div class={card_class()}>
      <div class="flex flex-wrap items-center gap-3 px-4 py-3">
        <div class="min-w-0 flex-1">
          <h1 class="text-base font-semibold text-neutral-950 dark:text-white">Extensions</h1>
          <p class="mt-0.5 truncate font-mono text-xs text-neutral-400 dark:text-neutral-500">
            {@panel.dir}
          </p>
        </div>

        <span
          :if={@action}
          class="flex items-center gap-2 text-xs text-neutral-500 dark:text-neutral-300"
        >
          <span class="size-3 animate-spin rounded-full border-2 border-neutral-300 border-t-neutral-600 dark:border-white/20 dark:border-t-white">
          </span>
          {@action.label}…
        </span>

        <span
          :if={!@panel.git?}
          class="rounded-full border border-amber-300/60 bg-amber-50 px-2 py-0.5 text-xs text-amber-900 dark:border-amber-400/30 dark:bg-amber-500/10 dark:text-amber-200"
          title="git was not found on PATH — disable still works, rollback does not"
        >
          no git — rollback unavailable
        </span>

        <button
          class={pill_button_class()}
          phx-click="ext_reload_all"
          disabled={@action != nil}
          type="button"
        >
          Reload all
        </button>
        <button
          :if={@panel.git?}
          class={pill_button_class()}
          phx-click="ext_rollback_last"
          disabled={@action != nil}
          data-confirm="Revert the most recent extension change (git revert) and reload?"
          type="button"
        >
          Roll back last change
        </button>
      </div>
    </div>
    """
  end

  defp boot_problem_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-amber-300/60 bg-amber-50/90 px-4 py-3 text-sm text-amber-900 shadow-sm dark:border-amber-400/30 dark:bg-amber-500/10 dark:text-amber-200">
      <p class="font-semibold">⚠ {boot_problem_title(@panel.boot_status)}</p>
      <p class="mt-1 text-xs leading-5">
        {boot_problem_reason(@panel.boot_status)} Fix or disable the offending file below
        (disabled extensions are skipped at boot), then load extensions again.
      </p>
      <button
        class="mt-2 rounded-full bg-amber-600 px-3 py-1.5 text-xs font-semibold text-white shadow-sm transition hover:bg-amber-500"
        phx-click="ext_reload_all"
        disabled={@action != nil}
        type="button"
      >
        Load extensions now
      </button>
    </div>
    """
  end

  defp boot_problem_title({:load_failed, _reason}), do: "Extension boot load failed"
  defp boot_problem_title(_status), do: "Safe mode — extensions were not loaded"

  defp boot_problem_reason({:safe_mode, :env}),
    do: "CATALYST_SAFE_MODE is set, so loading was skipped on purpose."

  defp boot_problem_reason({:safe_mode, :crash_detected}),
    do: "The previous boot died while extensions were active, so this boot skipped them."

  defp boot_problem_reason({:load_failed, reason}),
    do: "The boot-time load returned an error: #{Extensions.format_error(reason)}."

  defp boot_problem_reason(_other), do: "Extension loading was skipped."

  # ---- loaded / disabled ----------------------------------------------------------

  defp loaded_extensions(assigns) do
    ~H"""
    <section>
      <.section_title>Loaded extensions ({length(@panel.loaded)})</.section_title>

      <div
        :if={@panel.loaded == []}
        class="rounded-2xl border border-dashed border-neutral-300 px-4 py-6 text-center text-sm text-neutral-500 dark:border-white/15 dark:text-neutral-400"
      >
        No extensions loaded — only built-ins are active. Ask the agent to build one
        (“develop a tool that…”), or drop an <code class="font-mono">.ex</code>
        file into <code class="font-mono">{@panel.dir}</code>
        and reload.
      </div>

      <div class="flex flex-col gap-3">
        <div :for={ext <- @panel.loaded} class={card_class()} data-ext-owner={ext.owner}>
          <div class="flex flex-wrap items-center gap-2 border-b border-neutral-200/70 px-4 py-2.5 dark:border-white/10">
            <span class="font-mono text-sm font-semibold text-neutral-950 dark:text-white">
              {ext.owner}
            </span>
            <span
              :if={ext.path}
              class="truncate font-mono text-xs text-neutral-400 dark:text-neutral-500"
            >
              {Path.basename(ext.path)}
            </span>
            <span
              :if={is_nil(ext.path)}
              class="rounded-full bg-neutral-100 px-2 py-0.5 text-xs text-neutral-500 dark:bg-white/10 dark:text-neutral-300"
              title="Registered at runtime without a source file (e.g. by another app); reload/disable need a file"
            >
              no source file
            </span>
            <span
              :if={ext.path && !ext.managed?}
              class="rounded-full bg-neutral-100 px-2 py-0.5 text-xs text-neutral-500 dark:bg-white/10 dark:text-neutral-300"
              title="Loaded from outside the managed extensions directory; reload is available, but disable and rollback are not"
            >
              external source
            </span>
            <span
              :if={ext.processes > 0}
              class="rounded-full bg-emerald-100 px-2 py-0.5 text-xs text-emerald-800 dark:bg-emerald-500/15 dark:text-emerald-200"
            >
              {ext.processes} process(es)
            </span>

            <span class="flex-1"></span>

            <button
              :if={ext.path}
              class={pill_button_class()}
              phx-click="ext_reload"
              phx-value-owner={ext.owner}
              disabled={@action != nil}
              type="button"
            >
              Reload
            </button>
            <button
              :if={ext.managed? && @panel.git?}
              class={pill_button_class()}
              phx-click="ext_rollback"
              phx-value-owner={ext.owner}
              disabled={@action != nil}
              data-confirm={"Revert #{ext.owner}'s most recent change (git revert) and reload?"}
              type="button"
            >
              Roll back
            </button>
            <button
              :if={ext.managed?}
              class={danger_pill_button_class()}
              phx-click="ext_disable"
              phx-value-owner={ext.owner}
              disabled={@action != nil}
              type="button"
            >
              Disable
            </button>
          </div>

          <div class="flex flex-col gap-1.5 px-4 py-2.5 text-xs">
            <p
              :if={is_binary(ext.metadata[:description])}
              class="text-neutral-500 dark:text-neutral-400"
            >
              {ext.metadata[:description]}
            </p>
            <div :if={ext.tools != []} class="flex flex-wrap items-center gap-1.5">
              <span class="text-neutral-400 dark:text-neutral-500">tools</span>
              <code
                :for={tool <- ext.tools}
                class="rounded-full border border-indigo-200 bg-indigo-50 px-2 py-0.5 font-mono text-indigo-700 dark:border-indigo-400/20 dark:bg-indigo-400/10 dark:text-indigo-200"
              >
                {tool}
              </code>
            </div>
            <div :if={ext.modules != []} class="flex flex-wrap items-center gap-1.5">
              <span class="text-neutral-400 dark:text-neutral-500">modules</span>
              <code :for={mod <- ext.modules} class="font-mono text-neutral-600 dark:text-neutral-300">
                {inspect(mod)}
              </code>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp disabled_extensions(assigns) do
    ~H"""
    <section>
      <.section_title>Disabled ({length(@panel.disabled)})</.section_title>
      <div class="flex flex-col gap-2">
        <div
          :for={ext <- @panel.disabled}
          class="flex flex-wrap items-center gap-2 rounded-2xl border border-neutral-200 bg-neutral-50/80 px-4 py-2.5 opacity-80 dark:border-white/10 dark:bg-white/5"
          data-ext-owner={ext.owner}
        >
          <span class="font-mono text-sm font-semibold text-neutral-500 line-through dark:text-neutral-400">
            {ext.owner}
          </span>
          <span class="truncate font-mono text-xs text-neutral-400 dark:text-neutral-500">
            {Path.basename(ext.path)}
          </span>
          <span class="flex-1"></span>
          <button
            class={pill_button_class()}
            phx-click="ext_enable"
            phx-value-owner={ext.owner}
            disabled={@action != nil}
            type="button"
          >
            Enable
          </button>
        </div>
      </div>
    </section>
    """
  end

  # ---- registries -------------------------------------------------------------------

  defp effective_diagnostics(assigns) do
    ~H"""
    <section id="effective-extension-diagnostics">
      <.section_title>Effective diagnostics</.section_title>
      <div class={card_class()}>
        <div class="divide-y divide-neutral-100 dark:divide-white/5">
          <div
            :for={row <- @panel.effective}
            class="grid gap-1 px-4 py-2.5 text-xs sm:grid-cols-[10rem_1fr]"
          >
            <span class="font-medium text-neutral-500 dark:text-neutral-400">{row.label}</span>
            <div class="min-w-0">
              <code class={[
                "break-all font-mono",
                row.error? && "text-rose-600 dark:text-rose-300",
                !row.error? && "text-neutral-700 dark:text-neutral-200"
              ]}>
                {display_value(row.value)}
              </code>
              <p class="mt-0.5 break-all text-[0.65rem] text-neutral-400 dark:text-neutral-500">
                source: {display_value(row.source)}
              </p>
              <p
                :if={row.note}
                class="mt-0.5 text-[0.65rem] text-amber-600 dark:text-amber-300"
              >
                {row.note}
              </p>
            </div>
          </div>
        </div>

        <div
          :if={@prompt}
          id="effective-prompt-resolution"
          class="border-t border-neutral-200/70 px-4 py-3 dark:border-white/10"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <p class="text-xs font-semibold text-neutral-700 dark:text-neutral-200">
              {@prompt.label}
            </p>
            <code class="break-all font-mono text-[0.6rem] text-neutral-400">
              {@prompt.digest}
            </code>
          </div>
          <ol class="mt-2 space-y-1">
            <li
              :for={{source, index} <- Enum.with_index(@prompt.sources, 1)}
              class="flex gap-2 text-[0.65rem] text-neutral-500 dark:text-neutral-400"
            >
              <span class="font-mono text-neutral-300 dark:text-neutral-600">{index}.</span>
              <code class="break-all font-mono">{display_value(source)}</code>
            </li>
          </ol>
          <textarea
            id="extension-prompt-text"
            readonly
            rows="7"
            class="mt-3 w-full resize-y rounded-xl border border-neutral-200 bg-neutral-50 p-3 font-mono text-[0.7rem] leading-5 text-neutral-700 outline-none dark:border-white/10 dark:bg-white/5 dark:text-neutral-300"
          >{@prompt.text}</textarea>
        </div>
      </div>
    </section>
    """
  end

  defp runtime_overlays(assigns) do
    ~H"""
    <section id="runtime-overlay-registries">
      <.section_title>Owned runtime overlays</.section_title>
      <p class="mb-2 text-xs leading-5 text-neutral-500 dark:text-neutral-400">
        These rows contain only mutable runtime registrations. Effective fallback values are shown
        separately above.
      </p>
      <div class="flex flex-col gap-2">
        <.owned_registry_table label="Prompt registry" rows={@panel.prompt_runtime} />
        <.owned_registry_table label="Workflow registry" rows={@panel.workflow_runtime} />
        <.owned_registry_table label="Context registry" rows={@panel.context_runtime} />
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :rows, :list, required: true

  defp owned_registry_table(assigns) do
    ~H"""
    <details class={card_class()} data-runtime-registry={@label}>
      <summary class="cursor-pointer select-none px-4 py-2.5 text-sm font-medium text-neutral-700 dark:text-neutral-200">
        {@label}
        <span class="ml-1 text-xs text-neutral-400 dark:text-neutral-500">({length(@rows)})</span>
      </summary>
      <div class="border-t border-neutral-200/70 dark:border-white/10">
        <p :if={@rows == []} class="px-4 py-2.5 text-xs text-neutral-400 dark:text-neutral-500">
          (no runtime overlays)
        </p>
        <div
          :for={row <- @rows}
          class="grid gap-1 border-b border-neutral-100 px-4 py-2 text-xs last:border-b-0 sm:grid-cols-[minmax(8rem,1fr)_minmax(10rem,2fr)_auto] dark:border-white/5"
        >
          <code class="break-all font-mono font-semibold text-neutral-700 dark:text-neutral-200">
            {display_value(row.key)}
          </code>
          <code
            class="break-all font-mono text-neutral-400 dark:text-neutral-500"
            title={display_value(row.value, :full)}
          >
            {display_value(row.value)}
          </code>
          <.owner_badge owner={row.owner} />
        </div>
      </div>
    </details>
    """
  end

  defp registries(assigns) do
    ~H"""
    <section>
      <.section_title>Live registries</.section_title>
      <div class="flex flex-col gap-2">
        <.registry_table label="Tools" rows={@panel.tools}>
          <:row :let={t}>
            <code class="font-mono font-semibold">{t.name}</code>
            <span class="font-mono text-neutral-400 dark:text-neutral-500">{inspect(t.module)}</span>
            <.owner_badge owner={t.owner} />
          </:row>
        </.registry_table>

        <.registry_table label="LLM providers" rows={@panel.providers}>
          <:row :let={p}>
            <code class="font-mono font-semibold">{p.api}</code>
            <span class="font-mono text-neutral-400 dark:text-neutral-500">{inspect(p.module)}</span>
            <span :if={p.name} class="text-neutral-500 dark:text-neutral-400">{p.name}</span>
          </:row>
        </.registry_table>

        <.registry_table label="Loop hooks" rows={@panel.hooks}>
          <:row :let={h}>
            <code class="font-mono font-semibold">{h.point}</code>
            <span class="text-neutral-500 dark:text-neutral-400">{h.id} · priority {h.priority}</span>
            <.owner_badge owner={h.owner} />
          </:row>
        </.registry_table>

        <.registry_table label="Pages" rows={@panel.pages}>
          <:row :let={p}>
            <code class="font-mono font-semibold">/{p.path}</code>
            <span class="text-neutral-500 dark:text-neutral-400">{p.label}</span>
            <span class="font-mono text-neutral-400 dark:text-neutral-500">{inspect(p.mod)}</span>
            <.owner_badge owner={p.owner} />
          </:row>
        </.registry_table>

        <.registry_table label="Message renderers" rows={@panel.renderers}>
          <:row :let={r}>
            <code class="font-mono font-semibold">{r.kind}</code>
            <.owner_badge owner={r.owner} />
          </:row>
        </.registry_table>

        <.registry_table label="Slot components" rows={@panel.components}>
          <:row :let={c}>
            <code class="font-mono font-semibold">{c.slot}</code>
            <.owner_badge owner={c.owner} />
          </:row>
        </.registry_table>

        <.registry_table label="Commands" rows={@panel.commands}>
          <:row :let={c}>
            <code class="font-mono font-semibold">{c.name}</code>
            <span class="text-neutral-500 dark:text-neutral-400">{c.label}</span>
            <.owner_badge owner={c.owner} />
          </:row>
        </.registry_table>
      </div>
    </section>
    """
  end

  defp registry_table(assigns) do
    ~H"""
    <details class={card_class()}>
      <summary class="cursor-pointer select-none px-4 py-2.5 text-sm font-medium text-neutral-700 dark:text-neutral-200">
        {@label}
        <span class="ml-1 text-xs text-neutral-400 dark:text-neutral-500">({length(@rows)})</span>
      </summary>
      <div class="border-t border-neutral-200/70 dark:border-white/10">
        <p :if={@rows == []} class="px-4 py-2.5 text-xs text-neutral-400 dark:text-neutral-500">
          (empty)
        </p>
        <div
          :for={row <- @rows}
          class="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-neutral-100 px-4 py-1.5 text-xs last:border-b-0 dark:border-white/5"
        >
          {render_slot(@row, row)}
        </div>
      </div>
    </details>
    """
  end

  defp owner_badge(%{owner: nil} = assigns) do
    ~H"""
    <span class="rounded-full bg-neutral-100 px-2 py-0.5 text-[0.65rem] uppercase tracking-wide text-neutral-500 dark:bg-white/10 dark:text-neutral-400">
      built-in
    </span>
    """
  end

  defp owner_badge(assigns) do
    ~H"""
    <span class="rounded-full bg-indigo-100 px-2 py-0.5 font-mono text-[0.65rem] text-indigo-700 dark:bg-indigo-400/15 dark:text-indigo-200">
      {@owner}
    </span>
    """
  end

  # Effective-current-model diagnostics prefer the live selected-model preview.
  # Last-run prompt text belongs in chat diagnostics, not this panel.
  defp diagnostic_prompt(assigns) do
    case preview_prompt(Map.get(assigns, :prompt_preview)) do
      %{} = preview ->
        preview

      nil ->
        case Map.get(assigns, :run_metadata) do
          %{prompt: %{} = prompt} -> Map.put(prompt, :label, "Resolved run prompt")
          _no_run -> nil
        end
    end
  end

  defp preview_prompt({:ok, %{} = prompt}),
    do: Map.put(prompt, :label, "Selected-model prompt preview")

  defp preview_prompt(_preview), do: nil

  defp display_value(value, mode \\ :bounded) do
    rendered = inspect(value, limit: 30, printable_limit: 2_000)

    case mode do
      :full -> rendered
      :bounded -> bounded(rendered, 240)
    end
  end

  defp bounded(text, limit) do
    case String.length(text) > limit do
      true -> String.slice(text, 0, limit) <> "…"
      false -> text
    end
  end

  defp section_title(assigns) do
    ~H"""
    <h2 class="mb-2 text-xs font-semibold uppercase tracking-wide text-neutral-400 dark:text-neutral-500">
      {render_slot(@inner_block)}
    </h2>
    """
  end

  # ---- shared classes ----------------------------------------------------------------

  defp card_class do
    "overflow-hidden rounded-xl border border-neutral-200 bg-white " <>
      "dark:border-white/10 dark:bg-white/5"
  end

  defp pill_button_class do
    "rounded-full px-3 py-1 text-xs font-medium text-neutral-600 transition hover:bg-neutral-100 " <>
      "hover:text-neutral-950 disabled:cursor-not-allowed disabled:opacity-40 " <>
      "dark:text-neutral-300 dark:hover:bg-white/10 dark:hover:text-white " <>
      "border border-neutral-200 dark:border-white/10"
  end

  defp danger_pill_button_class do
    "rounded-full px-3 py-1 text-xs font-medium text-rose-600 transition hover:bg-rose-50 " <>
      "disabled:cursor-not-allowed disabled:opacity-40 dark:text-rose-300 " <>
      "dark:hover:bg-rose-500/10 border border-rose-200 dark:border-rose-400/20"
  end
end
