defmodule CatalystWeb.Workbench.IDEView do
  @moduledoc "Function-component render target for the built-in minimal IDE workbench."

  use CatalystWeb, :html

  @doc "Render the IDE from host-owned forms and serializable workbench state."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div
      id="ide-workbench"
      class="flex h-screen min-h-[36rem] flex-col overflow-hidden bg-bg text-ink"
    >
      <header class="flex h-14 shrink-0 items-center justify-between border-b border-edge bg-surface px-4">
        <div class="flex min-w-0 items-center gap-3">
          <div class="flex size-8 items-center justify-center rounded-lg bg-accent/10 text-accent">
            <.icon name="hero-code-bracket-square" class="size-5" />
          </div>
          <div class="min-w-0">
            <h1 class="text-sm font-semibold tracking-tight">Catalyst IDE</h1>
            <p id="workbench-workspace" class="truncate font-mono text-[10px] text-faint">
              {@workbench_state.workspace}
            </p>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <button
            id="workbench-apply-active"
            type="button"
            phx-click="workbench:host:remount"
            class="inline-flex items-center gap-2 rounded-lg border border-edge bg-raised px-3 py-1.5 text-xs font-medium text-muted transition hover:border-edge-strong hover:text-ink"
          >
            <.icon name="hero-arrow-path-rounded-square" class="size-4" /> Apply active workbench
          </button>
          <button
            id="command-palette-toggle"
            type="button"
            phx-click="workbench:ide:palette-toggle"
            class="inline-flex items-center gap-2 rounded-lg border border-edge bg-raised px-3 py-1.5 text-xs font-medium text-muted transition hover:border-edge-strong hover:text-ink"
          >
            <.icon name="hero-command-line" class="size-4" /> Commands
          </button>
          <.link
            id="workbench-agent-chat-link"
            navigate={~p"/"}
            class="inline-flex items-center gap-2 rounded-lg bg-accent px-3 py-1.5 text-xs font-semibold text-white shadow-sm transition hover:brightness-110"
          >
            <.icon name="hero-chat-bubble-left-right" class="size-4" /> Agent chat
          </.link>
        </div>
      </header>

      <div class="relative flex min-h-0 flex-1">
        <aside class="flex w-60 shrink-0 flex-col border-r border-edge bg-surface/80">
          <div class="flex h-10 items-center justify-between border-b border-edge px-3">
            <span class="text-[10px] font-semibold uppercase tracking-[0.18em] text-faint">Explorer</span>
            <button
              id="file-explorer-refresh"
              type="button"
              phx-click="workbench:ide:refresh"
              class="rounded p-1 text-faint transition hover:bg-raised hover:text-ink"
              aria-label="Refresh files"
            >
              <.icon
                name="hero-arrow-path"
                class={["size-3.5", @workbench_state.busy["files"] && "animate-spin"]}
              />
            </button>
          </div>

          <nav
            id="file-explorer"
            class="min-h-0 flex-1 overflow-auto p-2"
            aria-label="Workspace files"
          >
            <p
              :if={@workbench_state.files == []}
              id="file-explorer-empty"
              class="px-2 py-3 text-xs text-faint"
            >
              No files found.
            </p>
            <button
              :for={{path, index} <- Enum.with_index(@workbench_state.files)}
              id={"workspace-file-#{index}"}
              type="button"
              data-file-path={path}
              phx-click="workbench:ide:open"
              phx-value-path={path}
              class={[
                "flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left font-mono text-[11px] transition",
                path == @workbench_state.active_file && "bg-accent/10 text-accent",
                path != @workbench_state.active_file && "text-muted hover:bg-raised hover:text-ink"
              ]}
            >
              <.icon name="hero-document-text" class="size-3.5 shrink-0" />
              <span class="truncate">{path}</span>
            </button>
          </nav>

          <div class="border-t border-edge p-3">
            <.link
              id="workbench-agent-pane-link"
              navigate={~p"/"}
              class="flex items-center gap-2 rounded-lg border border-edge bg-bg px-3 py-2 text-xs text-muted transition hover:border-accent/50 hover:text-accent"
            >
              <.icon name="hero-sparkles" class="size-4" />
              <span>Ask the coding agent</span>
            </.link>
          </div>
        </aside>

        <main class="grid min-w-0 flex-1 grid-rows-[minmax(0,1fr)_14rem]">
          <section class="flex min-h-0 flex-col bg-bg">
            <div class="flex h-10 shrink-0 items-center justify-between border-b border-edge bg-raised/50 px-3">
              <span id="active-editor-file" class="truncate font-mono text-xs text-muted">
                {@workbench_state.active_file || "No file open"}
                <span :if={@workbench_state.editor_dirty} class="ml-1 text-accent">●</span>
              </span>
              <button
                id="editor-save-button"
                type="submit"
                form="editor-form"
                disabled={is_nil(@workbench_state.active_file) || @workbench_state.busy["save"]}
                class="inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-xs font-medium text-muted transition hover:bg-raised hover:text-ink disabled:cursor-not-allowed disabled:opacity-40"
              >
                <.icon name="hero-arrow-down-tray" class="size-3.5" /> Save
              </button>
            </div>

            <.form
              for={@workbench_forms.editor}
              id="editor-form"
              phx-change="workbench:ide:editor"
              phx-submit="workbench:ide:save"
              class="min-h-0 flex-1"
            >
              <.input
                field={@workbench_forms.editor[:content]}
                type="textarea"
                id="editor-content"
                readonly={is_nil(@workbench_state.active_file)}
                container_class="h-full"
                class="h-full w-full resize-none border-0 bg-bg p-5 font-mono text-[13px] leading-6 text-ink outline-none placeholder:text-faint focus:ring-0"
                placeholder="Select a file from the explorer"
              />
            </.form>
          </section>

          <section class="flex min-h-0 flex-col border-t border-edge bg-[#111318] text-slate-200">
            <div class="flex h-9 shrink-0 items-center justify-between border-b border-white/10 px-3">
              <span class="text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-400">Terminal task</span>
              <span
                :if={@workbench_state.busy["command"]}
                id="terminal-running"
                class="text-[10px] text-amber-300"
              >
                running…
              </span>
            </div>
            <pre
              id="command-output"
              class="min-h-0 flex-1 overflow-auto whitespace-pre-wrap px-4 py-3 font-mono text-xs leading-5 text-slate-300"
            >{@workbench_state.output}</pre>
            <.form
              for={@workbench_forms.terminal}
              id="terminal-form"
              phx-submit="workbench:ide:run"
              class="flex items-center gap-2 border-t border-white/10 px-3 py-2"
            >
              <span class="font-mono text-xs text-emerald-400">$</span>
              <.input
                field={@workbench_forms.terminal[:command]}
                id="terminal-command"
                autocomplete="off"
                container_class="min-w-0 flex-1"
                class="w-full border-0 bg-transparent px-1 py-1 font-mono text-xs text-slate-100 outline-none placeholder:text-slate-600 focus:ring-0"
                placeholder="Run a command in this workspace"
              />
              <button
                id="terminal-run-button"
                type="submit"
                disabled={@workbench_state.busy["command"]}
                class="rounded-md bg-white/10 px-2.5 py-1 text-xs font-medium transition hover:bg-white/15 disabled:opacity-40"
              >
                Run
              </button>
            </.form>
          </section>
        </main>

        <div
          :if={@workbench_state.palette_open}
          id="command-palette"
          class="absolute inset-x-0 top-10 z-30 mx-auto w-[min(34rem,calc(100%-2rem))] overflow-hidden rounded-xl border border-edge bg-surface shadow-2xl"
        >
          <div class="border-b border-edge px-4 py-3 text-xs font-semibold text-muted">
            Workbench commands
          </div>
          <div class="p-2">
            <button
              :for={{action, label, icon} <- palette_actions()}
              id={"palette-#{action}"}
              type="button"
              phx-click="workbench:ide:palette"
              phx-value-action={action}
              class="flex w-full items-center gap-3 rounded-lg px-3 py-2 text-left text-sm text-muted transition hover:bg-raised hover:text-ink"
            >
              <.icon name={icon} class="size-4" /> {label}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp palette_actions do
    [
      {"chat", "Open agent chat", "hero-chat-bubble-left-right"},
      {"save", "Save active file", "hero-arrow-down-tray"},
      {"refresh", "Refresh file explorer", "hero-arrow-path"},
      {"clear", "Clear command output", "hero-trash"}
    ]
  end
end
