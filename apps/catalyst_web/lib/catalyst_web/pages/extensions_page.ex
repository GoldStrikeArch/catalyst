defmodule CatalystWeb.Pages.ExtensionsPage do
  @moduledoc """
  Extensions panel — built-in `"extensions"` page.

  Loaded/disabled lists, boot status with safe-mode recovery, per-extension
  reload/rollback/disable/enable, and live registry contents (recovery UX).
  Data comes from `CatalystWeb.ShellLive.ExtensionsPanel` (`@ext_panel`);
  `ext_*` events are handled in `ShellLive`.
  """
  use CatalystWeb, :html

  alias Catalyst.Extensions
  alias CatalystWeb.ShellLive.ExtensionsPanel

  @doc "Panel-data snapshot; see `CatalystWeb.ShellLive.ExtensionsPanel.build/3`."
  defdelegate panel_data(model \\ nil, opts \\ [], diagnostics \\ %{}),
    to: ExtensionsPanel,
    as: :build

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
      <p :if={is_nil(@ext_panel)} class="mx-auto mt-24 max-w-md text-center text-sm text-muted">
        Loading extension data…
      </p>
    </main>
    """
  end

  defp panel_header(assigns) do
    ~H"""
    <div class={card_class()}>
      <div class="flex flex-wrap items-center gap-3 px-4 py-3">
        <div class="min-w-0 flex-1">
          <h1 class="text-base font-semibold text-ink">Extensions</h1>
          <p class="mt-0.5 truncate font-mono text-xs text-faint">{@panel.dir}</p>
        </div>
        <span :if={@action} class="flex items-center gap-2 text-xs text-muted">
          <span class="size-3 animate-spin rounded-full border-2 border-edge-strong border-t-muted"></span>
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
    {title, reason} = Extensions.describe_boot_status(assigns.panel.boot_status)
    assigns = assign(assigns, boot_title: title, boot_reason: reason)

    ~H"""
    <div
      id="extension-boot-problem"
      class="rounded-2xl border border-amber-300/60 bg-amber-50/90 px-4 py-3 text-sm text-amber-900 shadow-sm dark:border-amber-400/30 dark:bg-amber-500/10 dark:text-amber-200"
    >
      <p class="font-semibold">⚠ {@boot_title}</p>
      <p class="mt-1 text-xs leading-5">
        {@boot_reason} Fix or disable the offending file below
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

  defp loaded_extensions(assigns) do
    ~H"""
    <section id="loaded-extensions">
      <.section_title>Loaded extensions ({length(@panel.loaded)})</.section_title>
      <div
        :if={@panel.loaded == []}
        class="rounded-2xl border border-dashed border-edge-strong px-4 py-6 text-center text-sm text-muted"
      >
        No extensions loaded — only built-ins are active. Ask the agent to build one
        (“develop a tool that…”), or drop an <code class="font-mono">.ex</code>
        file into <code class="font-mono">{@panel.dir}</code>
        and reload.
      </div>
      <div class="flex flex-col gap-3">
        <.loaded_card :for={ext <- @panel.loaded} ext={ext} action={@action} git?={@panel.git?} />
      </div>
    </section>
    """
  end

  defp loaded_card(assigns) do
    ~H"""
    <div class={card_class()} data-ext-owner={@ext.owner}>
      <div class="flex flex-wrap items-center gap-2 border-b border-edge px-4 py-2.5">
        <span class="font-mono text-sm font-semibold text-ink">{@ext.owner}</span>
        <span :if={@ext.path} class="truncate font-mono text-xs text-faint">
          {Path.basename(@ext.path)}
        </span>
        <span
          :if={is_nil(@ext.path)}
          class="rounded-full bg-raised px-2 py-0.5 text-xs text-muted"
          title="Registered at runtime without a source file (e.g. by another app); reload/disable need a file"
        >
          no source file
        </span>
        <span
          :if={@ext.path && !@ext.managed?}
          class="rounded-full bg-raised px-2 py-0.5 text-xs text-muted"
          title="Loaded from outside the managed extensions directory; reload is available, but disable and rollback are not"
        >
          external source
        </span>
        <span
          :if={@ext.status == :degraded}
          class="rounded-full bg-danger/10 px-2 py-0.5 text-xs text-danger"
          title={degraded_note(@ext.purge_failures)}
          data-degraded-owner={@ext.owner}
        >
          degraded
        </span>
        <span
          :if={is_integer(@ext.process_count) and @ext.process_count > 0}
          class="rounded-full bg-ok/10 px-2 py-0.5 text-xs text-ok"
        >
          {@ext.process_count} process(es)
        </span>
        <span class="flex-1"></span>
        <button
          :if={@ext.path}
          class={pill_button_class()}
          phx-click="ext_reload"
          phx-value-owner={@ext.owner}
          disabled={@action != nil}
          type="button"
        >
          Reload
        </button>
        <button
          :if={@ext.managed? && @git?}
          class={pill_button_class()}
          phx-click="ext_rollback"
          phx-value-owner={@ext.owner}
          disabled={@action != nil}
          data-confirm={"Revert #{@ext.owner}'s most recent change (git revert) and reload?"}
          type="button"
        >
          Roll back
        </button>
        <button
          :if={@ext.managed?}
          class={danger_pill_button_class()}
          phx-click="ext_disable"
          phx-value-owner={@ext.owner}
          disabled={@action != nil}
          type="button"
        >
          Disable
        </button>
      </div>
      <div class="flex flex-col gap-1.5 px-4 py-2.5 text-xs">
        <p :if={is_binary(@ext.metadata[:description])} class="text-muted">
          {@ext.metadata[:description]}
        </p>
        <p :if={@ext.status == :degraded} class="text-danger">
          {degraded_note(@ext.purge_failures)}
        </p>
        <div :if={@ext.tools != []} class="flex flex-wrap items-center gap-1.5">
          <span class="text-faint">tools</span>
          <code
            :for={tool <- @ext.tools}
            class="rounded-full border border-accent/40 bg-accent/10 px-2 py-0.5 font-mono text-accent"
          >
            {tool}
          </code>
        </div>
        <div :if={@ext.modules != []} class="flex flex-wrap items-center gap-1.5">
          <span class="text-faint">modules</span>
          <code :for={mod <- @ext.modules} class="font-mono text-muted">{inspect(mod)}</code>
        </div>
      </div>
    </div>
    """
  end

  defp degraded_note(purge_failures) do
    "a previous purge left residue (retried on reload/disable) — failed: " <>
      Enum.map_join(purge_failures, ", ", &degraded_failure/1)
  end

  defp degraded_failure({{mod, fun, arity}, _reason}), do: "#{inspect(mod)}.#{fun}/#{arity}"
  defp degraded_failure({key, _reason}), do: display_value(key)

  defp disabled_extensions(assigns) do
    ~H"""
    <section>
      <.section_title>Disabled ({length(@panel.disabled)})</.section_title>
      <div class="flex flex-col gap-2">
        <div
          :for={ext <- @panel.disabled}
          class="flex flex-wrap items-center gap-2 rounded-2xl border border-edge bg-raised px-4 py-2.5 opacity-80"
          data-ext-owner={ext.owner}
        >
          <span class="font-mono text-sm font-semibold text-muted line-through">{ext.owner}</span>
          <span class="truncate font-mono text-xs text-faint">{Path.basename(ext.path)}</span>
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

  defp effective_diagnostics(assigns) do
    ~H"""
    <section id="effective-extension-diagnostics">
      <.section_title>Effective diagnostics</.section_title>
      <div class={card_class()}>
        <div class="divide-y divide-edge">
          <div
            :for={row <- @panel.effective}
            class="grid gap-1 px-4 py-2.5 text-xs sm:grid-cols-[10rem_1fr]"
          >
            <span class="font-medium text-muted">{row.label}</span>
            <div class="min-w-0">
              <code class={[
                "break-all font-mono",
                row.error? && "text-danger",
                !row.error? && "text-ink"
              ]}>
                {display_value(row.value)}
              </code>
              <p class="mt-0.5 break-all text-[0.65rem] text-faint">
                source: {display_value(row.source)}
              </p>
              <p :if={row.note} class="mt-0.5 text-[0.65rem] text-amber-600 dark:text-amber-300">
                {row.note}
              </p>
            </div>
          </div>
        </div>
        <div :if={@prompt} id="effective-prompt-resolution" class="border-t border-edge px-4 py-3">
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <p class="text-xs font-semibold text-ink">{@prompt.label}</p>
            <code class="break-all font-mono text-[0.6rem] text-faint">{@prompt.digest}</code>
          </div>
          <ol class="mt-2 space-y-1">
            <li
              :for={{source, index} <- Enum.with_index(@prompt.sources, 1)}
              class="flex gap-2 text-[0.65rem] text-muted"
            >
              <span class="font-mono text-faint">{index}.</span>
              <code class="break-all font-mono">{display_value(source)}</code>
            </li>
          </ol>
          <textarea
            id="extension-prompt-text"
            readonly
            rows="7"
            class="mt-3 w-full resize-y rounded-xl border border-edge bg-raised p-3 font-mono text-[0.7rem] leading-5 text-ink outline-none"
          >{@prompt.text}</textarea>
        </div>
      </div>
    </section>
    """
  end

  defp runtime_overlays(assigns) do
    assigns = assign(assigns, :tables, overlay_tables(assigns.panel))

    ~H"""
    <section id="runtime-overlay-registries">
      <.section_title>Owned runtime overlays</.section_title>
      <p class="mb-2 text-xs leading-5 text-muted">
        These rows contain only mutable runtime registrations. Effective fallback values are shown
        separately above.
      </p>
      <div class="flex flex-col gap-2">
        <.rows_table
          :for={{label, rows} <- @tables}
          label={label}
          rows={rows}
          registry={label}
          empty="(no runtime overlays)"
        />
      </div>
    </section>
    """
  end

  defp registries(assigns) do
    assigns = assign(assigns, :tables, live_tables(assigns.panel))

    ~H"""
    <section id="live-registries">
      <.section_title>Live registries</.section_title>
      <div class="flex flex-col gap-2">
        <.rows_table :for={{label, rows} <- @tables} label={label} rows={rows} />
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :rows, :list, required: true
  attr :registry, :string, default: nil
  attr :empty, :string, default: "(empty)"

  defp rows_table(assigns) do
    ~H"""
    <details class={card_class()} data-runtime-registry={@registry}>
      <summary class="cursor-pointer select-none px-4 py-2.5 text-sm font-medium text-ink">
        {@label}
        <span class="ml-1 text-xs text-faint">({length(@rows)})</span>
      </summary>
      <div class="border-t border-edge">
        <p :if={@rows == []} class="px-4 py-2.5 text-xs text-faint">{@empty}</p>
        <div
          :for={row <- @rows}
          class="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-edge px-4 py-1.5 text-xs last:border-b-0"
        >
          <code class="break-all font-mono font-semibold text-ink">{row.primary}</code>
          <span :if={row[:secondary]} class="break-all font-mono text-faint" title={row[:title]}>
            {row.secondary}
          </span>
          <span :if={row[:extra]} class="text-muted">{row.extra}</span>
          <.owner_badge :if={Map.has_key?(row, :owner)} owner={row.owner} />
        </div>
      </div>
    </details>
    """
  end

  defp owner_badge(%{owner: nil} = assigns) do
    ~H"""
    <span class="rounded-full bg-raised px-2 py-0.5 text-[0.65rem] uppercase tracking-wide text-muted">
      built-in
    </span>
    """
  end

  defp owner_badge(assigns) do
    ~H"""
    <span class="rounded-full bg-accent/10 px-2 py-0.5 font-mono text-[0.65rem] text-accent">
      {@owner}
    </span>
    """
  end

  defp overlay_tables(panel) do
    [
      {"Prompt registry", panel.prompt_runtime},
      {"Workflow registry", panel.workflow_runtime},
      {"Context registry", panel.context_runtime}
    ]
    |> Enum.map(fn {label, rows} ->
      {label,
       Enum.map(rows, fn row ->
         %{
           primary: display_value(row.key),
           secondary: display_value(row.value),
           title: display_value(row.value, :full),
           owner: row.owner
         }
       end)}
    end)
  end

  defp live_tables(panel) do
    [
      {"Tools",
       Enum.map(
         panel.tools,
         &%{primary: &1.name, secondary: inspect(&1.module), owner: &1.owner}
       )},
      {"LLM providers",
       Enum.map(
         panel.providers,
         &%{primary: &1.api, secondary: inspect(&1.module), extra: &1.name}
       )},
      {"Loop hooks",
       Enum.map(
         panel.hooks,
         &%{primary: &1.point, extra: "#{&1.id} · priority #{&1.priority}", owner: &1.owner}
       )},
      {"Pages",
       Enum.map(
         panel.pages,
         &%{
           primary: "/#{&1.path}",
           extra: &1.label,
           secondary: inspect(&1.mod),
           owner: &1.owner
         }
       )},
      {"Message renderers", Enum.map(panel.renderers, &%{primary: &1.kind, owner: &1.owner})},
      {"Slot components", Enum.map(panel.components, &%{primary: &1.slot, owner: &1.owner})},
      {"Commands",
       Enum.map(panel.commands, &%{primary: &1.name, extra: &1.label, owner: &1.owner})}
    ]
  end

  defp diagnostic_prompt(assigns) do
    case {preview_prompt(Map.get(assigns, :prompt_preview)), Map.get(assigns, :run_metadata)} do
      {%{} = preview, _} -> preview
      {_, %{prompt: %{} = prompt}} -> Map.put(prompt, :label, "Resolved run prompt")
      _no_prompt -> nil
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
    <h2 class="mb-2 text-xs font-semibold uppercase tracking-wide text-faint">
      {render_slot(@inner_block)}
    </h2>
    """
  end

  defp card_class, do: "overflow-hidden rounded-xl border border-edge bg-surface"

  defp pill_button_class,
    do:
      "rounded-full px-3 py-1 text-xs font-medium text-muted transition hover:bg-raised " <>
        "hover:text-ink disabled:cursor-not-allowed disabled:opacity-40 border border-edge"

  defp danger_pill_button_class,
    do:
      "rounded-full px-3 py-1 text-xs font-medium text-danger transition hover:bg-danger/10 " <>
        "disabled:cursor-not-allowed disabled:opacity-40 border border-danger/40"
end
