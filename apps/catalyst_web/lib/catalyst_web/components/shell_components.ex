defmodule CatalystWeb.ShellComponents do
  @moduledoc """
  Rendering for the persistent application shell around runtime-registered pages.

  The LiveView owns events and state transitions; this module owns shell chrome,
  the project/thread sidebar, Codex controls, extension recovery status, and
  delegation to the live UI registry. Keeping it stateless makes markup
  hot-swappable without moving process ownership out of `CatalystWeb.ShellLive`.
  """

  use CatalystWeb, :html

  alias CatalystWeb.UI.PageRenderer

  @doc """
  Renders the complete shell around the currently selected page.

  Expects `@codex_catalog`, `@selected_codex_entry`, `@shell_pages`, and
  `@thread_sidebar` to be assigned by `CatalystWeb.ShellLive` at its refresh
  points — they are not recomputed per render.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns =
      assign(assigns,
        codex_form: codex_form(assigns.codex_prefs),
        workflow_form: workflow_form(assigns.workflow_prefs),
        diagnostic_prompt: diagnostic_prompt(assigns),
        diagnostic_workflow: metadata_value(assigns.run_metadata, :workflow),
        diagnostic_context: metadata_value(assigns.run_metadata, :context)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      class="min-h-screen bg-neutral-50 text-neutral-900 antialiased dark:bg-neutral-900 dark:text-neutral-100"
    >
      <div
        id="catalyst-shell"
        data-session-id={@session_id || ""}
        class="flex h-screen flex-col bg-neutral-50 dark:bg-neutral-900"
      >
        <header
          id="shell-header"
          class="relative z-40 flex min-h-12 shrink-0 items-center gap-2 border-b border-neutral-200 bg-neutral-50 px-3 py-1.5 dark:border-white/10 dark:bg-neutral-900"
        >
          <button
            id="sidebar-toggle"
            type="button"
            phx-click="toggle_sidebar"
            aria-pressed={to_string(@ui_prefs.sidebar)}
            aria-controls="shell-sidebar"
            title={if(@ui_prefs.sidebar, do: "Hide sidebar", else: "Show sidebar")}
            class="flex size-8 shrink-0 items-center justify-center rounded-lg text-neutral-500 transition hover:bg-neutral-200/60 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-white/10 dark:hover:text-white"
          >
            <.icon name="hero-bars-3" class="size-4" />
          </button>

          <span :if={@running} class="flex items-center gap-1" aria-label="Agent running">
            <span class="size-1.5 animate-pulse rounded-full bg-indigo-500"></span>
            <span class="size-1.5 animate-pulse rounded-full bg-indigo-500 delay-150"></span>
            <span class="size-1.5 animate-pulse rounded-full bg-indigo-500 delay-300"></span>
          </span>

          <nav
            :if={length(@shell_pages) > 1}
            id="shell-page-nav"
            class="flex min-w-0 items-center gap-1"
          >
            <.link
              :for={page <- @shell_pages}
              id={"page-nav-#{page.path}"}
              patch={~p"/#{page.path}"}
              class={[
                "rounded-full px-3 py-1 text-xs font-medium transition",
                @page == page.path &&
                  "bg-neutral-200/70 text-neutral-900 dark:bg-white/10 dark:text-white",
                @page != page.path &&
                  "text-neutral-500 hover:bg-neutral-200/50 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-white/5 dark:hover:text-white"
              ]}
            >
              {page.label}
            </.link>
          </nav>

          {PageRenderer.render_components(:header_extra, assigns)}

          <div class="ml-auto flex shrink-0 items-center gap-1.5">
            <Layouts.theme_toggle />

            <%= if @logged_in do %>
              <button
                id="logout-button"
                class="rounded-full p-2 text-neutral-500 transition hover:bg-neutral-200/60 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-white/10 dark:hover:text-white"
                phx-click="logout"
                title="Sign out of ChatGPT"
                type="button"
              >
                <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
              </button>
            <% else %>
              <button
                :if={@login_state != :pending}
                id="login-button"
                class="rounded-full bg-neutral-900 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-neutral-700 dark:bg-white dark:text-neutral-900 dark:hover:bg-neutral-200"
                phx-click="login"
                type="button"
              >
                Sign in to ChatGPT
              </button>
              <span
                :if={@login_state == :pending}
                id="login-pending"
                class="flex items-center gap-2 text-xs text-neutral-500 dark:text-neutral-400"
              >
                <span class="size-3 animate-spin rounded-full border-2 border-neutral-300 border-t-neutral-600 dark:border-white/20 dark:border-t-white">
                </span>
                finish in your browser…
              </span>
            <% end %>
          </div>
        </header>

        <div
          :if={@boot_status != :ok}
          id="extension-boot-status"
          class="border-b border-amber-300/60 bg-amber-50 px-4 py-2 text-xs text-amber-900 dark:border-amber-400/30 dark:bg-amber-500/10 dark:text-amber-200"
        >
          ⚠ {boot_status_heading(@boot_status)} — {boot_status_reason(@boot_status)} Recover from the
          <.link patch={~p"/extensions"} class="font-semibold underline">Extensions panel</.link>
          (disable or roll back the offender, then load again), or ask the agent to run <code class="font-mono">reload_extensions</code>.
        </div>

        <div class="flex min-h-0 flex-1">
          <.sidebar sidebar={@thread_sidebar} open?={@ui_prefs.sidebar} root={assigns} />

          <div class="flex min-h-0 min-w-0 flex-1 flex-col">
            <div class={[
              "min-h-0 flex-1",
              @page == "chat" && "flex flex-col",
              @page != "chat" && "overflow-y-auto"
            ]}>
              {PageRenderer.render(assigns)}
            </div>

            <footer
              id="shell-footer"
              class="relative z-30 shrink-0 border-t border-neutral-200 bg-neutral-50 dark:border-white/10 dark:bg-neutral-900"
            >
              <.file_search_popover :if={@page == "chat"} file_search={@file_search} />
              <.composer :if={@page == "chat"} {assigns} />
              <.run_bar
                cwd={@cwd}
                context_status={@context_status}
                diagnostic_prompt={@diagnostic_prompt}
                diagnostic_workflow={@diagnostic_workflow}
                diagnostic_context={@diagnostic_context}
                prompt_preview={@prompt_preview}
                diagnostics_open={@diagnostics_open}
                ui_prefs={@ui_prefs}
                machine_prefs={@machine_prefs}
                workflow_form={@workflow_form}
                workflow_options={@workflow_options}
                workflow_prefs={@workflow_prefs}
                codex_form={@codex_form}
                codex_catalog={@codex_catalog}
                selected_codex_entry={@selected_codex_entry}
                codex_prefs={@codex_prefs}
              />
            </footer>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :sidebar, :map, required: true
  attr :open?, :boolean, required: true
  attr :root, :map, required: true

  defp sidebar(assigns) do
    ~H"""
    <aside
      :if={@open?}
      id="shell-sidebar"
      class="flex w-60 shrink-0 flex-col overflow-y-auto border-r border-neutral-200 bg-neutral-100/70 dark:border-white/10 dark:bg-neutral-950/40"
    >
      {PageRenderer.render_components(:sidebar, @root)}

      <section id="sidebar-projects" class="px-2 pb-2 pt-3">
        <p class="mb-1 px-2 text-[0.65rem] font-semibold uppercase tracking-wide text-neutral-400 dark:text-neutral-500">
          Projects
        </p>

        <p
          :if={@sidebar.projects == []}
          class="px-2 py-3 text-xs text-neutral-400 dark:text-neutral-500"
        >
          No threads yet
        </p>

        <div :for={project <- @sidebar.projects} id={project.id} class="mb-1">
          <div class="flex items-center gap-1 rounded-md px-2 py-1">
            <.icon name="hero-folder" class="size-3.5 shrink-0 text-neutral-400" />
            <span class="min-w-0 flex-1 truncate text-xs font-medium text-neutral-700 dark:text-neutral-200">
              {project.label}
            </span>
          </div>

          <div
            :for={thread <- project.threads}
            id={"thread-#{thread.id}"}
            class={[
              "flex items-center gap-1 rounded-md py-0.5 pl-6 pr-1",
              thread.current? && "bg-neutral-200/80 dark:bg-white/10",
              !thread.current? && "hover:bg-neutral-200/50 dark:hover:bg-white/5"
            ]}
          >
            <button
              id={"switch-thread-#{thread.id}"}
              type="button"
              phx-click="switch_session"
              phx-value-id={thread.id}
              class={[
                "flex min-w-0 flex-1 items-center gap-2 rounded-md px-1 py-1 text-left text-xs transition",
                thread.current? && "text-neutral-900 dark:text-white",
                !thread.current? &&
                  "text-neutral-500 hover:text-neutral-800 dark:text-neutral-400 dark:hover:text-neutral-200"
              ]}
            >
              <span class={[
                "size-1.5 shrink-0 rounded-full",
                thread.live? && "bg-emerald-500/80",
                !thread.live? && "bg-neutral-300 dark:bg-neutral-600"
              ]}>
              </span>
              <span class="min-w-0 truncate">{thread.title}</span>
            </button>
            <button
              id={"close-thread-#{thread.id}"}
              type="button"
              phx-click="close_session"
              phx-value-id={thread.id}
              title="Close thread"
              class="rounded p-0.5 text-neutral-400 transition hover:bg-neutral-300/70 hover:text-neutral-800 dark:hover:bg-white/10 dark:hover:text-white"
            >
              <.icon name="hero-x-mark" class="size-3" />
            </button>
          </div>
        </div>
      </section>
    </aside>
    """
  end

  attr :file_search, :any, default: nil

  defp file_search_popover(assigns) do
    ~H"""
    <div
      :if={@file_search}
      id="file-search-results"
      class="border-b border-neutral-200 bg-neutral-50 px-4 py-2 dark:border-white/10 dark:bg-neutral-900"
    >
      <div class="mx-auto max-w-5xl">
        <p class="text-[0.65rem] font-semibold uppercase tracking-wide text-neutral-400 dark:text-neutral-500">
          <%= if @file_search.results == [] do %>
            no files match “@{@file_search.query}”
          <% else %>
            files matching “@{@file_search.query}” — Enter picks the first
          <% end %>
        </p>
        <div class="mt-1 flex flex-col">
          <button
            :for={r <- @file_search.results}
            type="button"
            phx-click="pick_file"
            phx-value-label={r.label}
            phx-value-path={r.path}
            class="flex items-baseline gap-3 rounded-lg px-2 py-1 text-left text-xs transition hover:bg-neutral-200/50 dark:hover:bg-white/10"
          >
            <code class="shrink-0 font-mono font-semibold text-neutral-900 dark:text-neutral-100">
              {r.label}
            </code>
            <span class="truncate font-mono text-neutral-400 dark:text-neutral-500">{r.path}</span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp composer(assigns) do
    ~H"""
    <.form
      for={@chat_form}
      id="chat-form"
      phx-submit="send"
      phx-change="typing"
      phx-hook="PasteImages"
      class="px-4 pt-3"
    >
      <div
        :if={@uploads.image.entries != []}
        class="mx-auto mb-2 flex max-w-5xl flex-wrap items-center gap-2"
      >
        <div :for={entry <- @uploads.image.entries} class="relative" data-image-entry>
          <.live_img_preview
            entry={entry}
            class="h-16 w-16 rounded-lg border border-neutral-200 object-cover dark:border-white/10"
          />
          <button
            type="button"
            phx-click="cancel_image"
            phx-value-ref={entry.ref}
            aria-label="remove image"
            class="absolute -right-1.5 -top-1.5 flex size-5 items-center justify-center rounded-full bg-neutral-950 text-xs text-white shadow dark:bg-white dark:text-neutral-950"
          >
            ×
          </button>
          <span
            :if={not entry.done?}
            class="absolute inset-x-0 bottom-0 rounded-b-lg bg-neutral-950/70 text-center text-[0.6rem] text-white"
          >
            {entry.progress}%
          </span>
          <p :for={err <- upload_errors(@uploads.image, entry)} class="text-xs text-red-500">
            {upload_error_label(err)}
          </p>
        </div>
        <p :for={err <- upload_errors(@uploads.image)} class="text-xs text-red-500">
          {upload_error_label(err)}
        </p>
      </div>

      <div class="mx-auto max-w-5xl">
        <div class="flex items-center gap-2 rounded-2xl border border-neutral-300 bg-white py-1.5 pl-2 pr-1.5 transition focus-within:border-neutral-400 dark:border-white/15 dark:bg-white/5 dark:focus-within:border-white/30">
          <.input
            field={@chat_form[:message]}
            type="text"
            autocomplete="off"
            phx-debounce="150"
            placeholder="Ask Catalyst…  (@ references a file, paste an image to attach it)"
            container_class="m-0 min-w-0 flex-1"
            class="w-full border-0 bg-transparent px-2 py-1.5 text-sm text-neutral-900 outline-none placeholder:text-neutral-400 focus:ring-0 dark:text-white dark:placeholder:text-neutral-500"
          />
          <.live_file_input upload={@uploads.image} class="hidden" />
          <button
            :if={!@running}
            id="chat-send"
            type="submit"
            aria-label="Send"
            title="Send"
            class="flex size-8 shrink-0 items-center justify-center rounded-full bg-neutral-900 text-white transition hover:bg-neutral-700 dark:bg-white dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            <.icon name="hero-arrow-up" class="size-4" />
          </button>
          <button
            :if={@running}
            id="chat-stop"
            type="button"
            phx-click="abort"
            aria-label="Stop"
            title="Stop the run"
            class="flex size-8 shrink-0 items-center justify-center rounded-full bg-neutral-900 text-white transition hover:bg-neutral-700 dark:bg-white dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            <.icon name="hero-stop-solid" class="size-3.5" />
          </button>
        </div>
      </div>
    </.form>
    """
  end

  defp run_bar(assigns) do
    ~H"""
    <div
      id="shell-run-bar"
      class="mx-auto flex w-full max-w-5xl flex-wrap items-center gap-1.5 px-4 py-2"
    >
      <div id="shell-header-status" class="flex min-w-0 items-center gap-2">
        <.icon name="hero-folder" class="size-3.5 shrink-0 text-neutral-400" />
        <span
          id="header-cwd"
          class="min-w-0 truncate font-mono text-xs text-neutral-400 dark:text-neutral-500"
          title={"#{@cwd} — change with /cd <path>"}
        >
          {short_cwd(@cwd)}
        </span>
        <button
          id="new-session-button"
          class="rounded-md p-1 text-neutral-400 transition hover:bg-neutral-200/60 hover:text-neutral-800 dark:hover:bg-white/10 dark:hover:text-white"
          phx-click="new_session"
          type="button"
          title="New thread"
        >
          <.icon name="hero-plus" class="size-3.5" />
        </button>
        <.context_meter :if={@context_status} status={@context_status} />
      </div>

      <div
        id="shell-header-controls"
        class="ml-auto flex min-w-0 flex-wrap items-center justify-end gap-1.5"
      >
        <button
          id="quiet-toggle"
          type="button"
          phx-click="toggle_quiet"
          title="Quiet mode: hide tool calls/results and thinking (display only)"
          class={quiet_button_class(@ui_prefs.quiet)}
        >
          <.icon name="hero-eye-slash" class="size-3.5" /> Quiet
        </button>

        <button
          id="computer-toggle"
          type="button"
          phx-click="toggle_computer_use"
          aria-pressed={to_string(@machine_prefs.computer_use)}
          title="Computer use: let the agent see the screen and drive this machine. Full access, no sandbox — applies to the next run and is never inherited by subagents."
          class={computer_button_class(@machine_prefs.computer_use)}
        >
          <.icon name="hero-computer-desktop" class="size-3.5" /> Computer
        </button>

        <.form
          :if={show_workflow_picker?(@workflow_options, @workflow_prefs)}
          for={@workflow_form}
          id="workflow-form"
          phx-change="select_workflow"
          class="m-0 flex items-center"
        >
          <.input
            field={@workflow_form[:workflow]}
            id="workflow-select"
            type="select"
            options={workflow_select_options(@workflow_options)}
            container_class="m-0"
            class={codex_select_class()}
            title="Agent workflow (applies to the next run)"
          />
        </.form>

        <div id="codex-control-group" class="flex min-w-0 max-w-full flex-wrap items-center gap-1.5">
          <.form
            for={@codex_form}
            id="codex-opts"
            phx-change="codex_opts"
            class="flex min-w-0 max-w-full flex-wrap items-center gap-1.5"
          >
            <.input
              field={@codex_form[:model]}
              type="select"
              options={Enum.map(@codex_catalog, &{&1.name, &1.id})}
              container_class="m-0"
              class={codex_select_class()}
              title="Codex model"
            />
            <.input
              field={@codex_form[:effort]}
              type="select"
              options={@selected_codex_entry.efforts}
              container_class="m-0"
              class={codex_select_class()}
              title="Reasoning effort"
            />
            <.input
              field={@codex_form[:transport]}
              type="select"
              options={[{"auto", "auto"}, {"ws", "websocket"}, {"sse", "sse"}]}
              container_class="m-0"
              class={codex_select_class()}
              title="Transport: auto = websocket with SSE fallback"
            />
          </.form>
          <button
            :if={@selected_codex_entry.fast?}
            id="codex-fast-toggle"
            type="button"
            phx-click="codex_fast"
            title="Fast mode (priority service tier): ~1.5x speed, increased usage"
            class={fast_button_class(@codex_prefs.fast)}
          >
            ⚡ Fast
          </button>
        </div>

        <.run_diagnostics
          prompt={@diagnostic_prompt}
          workflow={@diagnostic_workflow}
          context={@diagnostic_context}
          preview={@prompt_preview}
          open={@diagnostics_open}
        />
      </div>
    </div>
    """
  end

  defp codex_form(prefs) do
    to_form(%{
      "model" => prefs.model,
      "effort" => prefs.effort,
      "transport" => prefs.transport
    })
  end

  defp workflow_form(prefs) do
    to_form(%{"workflow" => prefs.workflow || ""})
  end

  defp show_workflow_picker?(options, prefs) do
    length(options) > 1 or prefs.workflow != nil
  end

  defp workflow_select_options(options) do
    Enum.map(options, fn
      %{name: :default, source: source} -> {"default" <> workflow_suffix(source), ""}
      %{name: name, source: source} -> {name <> workflow_suffix(source), name}
    end)
  end

  defp workflow_suffix(:builtin), do: ""
  defp workflow_suffix(:unavailable), do: " (unavailable)"
  defp workflow_suffix({:runtime, _owner, _key}), do: " (extension)"
  defp workflow_suffix({:application, _setting}), do: " (config)"
  defp workflow_suffix({:template, _metadata}), do: " (template)"
  defp workflow_suffix(_source), do: ""

  attr :status, :map, required: true

  defp context_meter(assigns) do
    used = nonnegative(assigns.status[:used_tokens])
    threshold = positive(assigns.status[:threshold])

    assigns =
      assign(assigns,
        used: used,
        threshold: threshold,
        state_label: if(assigns.status[:anchored], do: "anchored", else: "estimated"),
        source_label: source_label(assigns.status[:threshold_source])
      )

    ~H"""
    <div
      id="context-meter"
      class="hidden shrink-0 items-center gap-2 whitespace-nowrap rounded-full border border-neutral-200 px-2.5 py-1 text-[0.65rem] text-neutral-500 sm:flex dark:border-white/10 dark:text-neutral-400"
      title={"Context threshold source: #{@source_label}"}
    >
      <.icon
        name="hero-circle-stack-micro"
        class="size-3.5 shrink-0 text-neutral-400 dark:text-neutral-500"
      />
      <progress
        :if={@threshold}
        id="context-progress"
        value={min(@used, @threshold)}
        max={@threshold}
        class="hidden h-1.5 w-16 overflow-hidden rounded-full accent-indigo-500 xl:block"
      >
        {@used} / {@threshold}
      </progress>
      <span id="context-token-count" class="whitespace-nowrap font-mono">
        {format_tokens(@used)} / {format_threshold(@threshold)}
      </span>
      <span
        id="context-estimate-state"
        class={[
          "rounded-full px-1.5 py-0.5 font-semibold",
          @status[:anchored] &&
            "bg-emerald-100 text-emerald-700 dark:bg-emerald-400/15 dark:text-emerald-200",
          !@status[:anchored] &&
            "bg-amber-100 text-amber-700 dark:bg-amber-400/15 dark:text-amber-200"
        ]}
      >
        {@state_label}
      </span>
      <span
        id="context-threshold-source"
        class="hidden max-w-24 truncate text-neutral-400 xl:inline dark:text-neutral-500"
      >
        {@source_label}
      </span>
    </div>
    """
  end

  attr :prompt, :map, default: nil
  attr :workflow, :map, default: nil
  attr :context, :map, default: nil
  attr :preview, :any, default: nil
  attr :open, :boolean, default: false

  defp run_diagnostics(assigns) do
    ~H"""
    <div
      :if={@prompt || @workflow || @context || @preview == :loading || match?({:error, _}, @preview)}
      id="run-diagnostics"
      data-open={to_string(@open)}
      class="relative ml-1 hidden shrink-0 md:block"
    >
      <button
        id="run-diagnostics-toggle"
        type="button"
        phx-click="toggle_diagnostics"
        aria-expanded={to_string(@open)}
        aria-controls="run-diagnostics-panel"
        class="flex max-w-full cursor-pointer items-center gap-1 overflow-hidden whitespace-nowrap rounded-full border border-neutral-200 px-2.5 py-1 text-[0.65rem] font-medium text-neutral-500 transition hover:border-neutral-300 hover:text-neutral-900 dark:border-white/10 dark:text-neutral-400 dark:hover:border-white/20 dark:hover:text-white"
      >
        <.icon name="hero-document-text-micro" class="size-3.5" />
        <%= cond do %>
          <% @prompt -> %>
            Prompt <code class="font-mono">{digest_prefix(@prompt.digest)}</code>
          <% @preview == :loading -> %>
            Resolving prompt…
          <% true -> %>
            Run details
        <% end %>
      </button>

      <div
        :if={@open}
        id="run-diagnostics-backdrop"
        class="fixed inset-0 z-40"
        phx-click="close_diagnostics"
      >
      </div>

      <div
        :if={@open}
        id="run-diagnostics-panel"
        phx-window-keydown="close_diagnostics"
        phx-key="Escape"
        class="fixed bottom-16 right-4 z-50 flex max-h-[min(70vh,36rem)] w-[min(38rem,calc(100vw-2rem))] flex-col overflow-hidden rounded-xl border border-neutral-200 bg-white text-xs shadow-xl shadow-neutral-950/10 dark:border-white/10 dark:bg-neutral-800 dark:shadow-black/40"
      >
        <div class="shrink-0 border-b border-neutral-200/70 px-4 py-3 dark:border-white/10">
          <p class="font-semibold text-neutral-900 dark:text-white">Run diagnostics</p>
          <p class="mt-0.5 text-[0.65rem] leading-4 text-neutral-400 dark:text-neutral-500">
            Read-only resolution data; it is never reused as configuration.
          </p>
        </div>

        <div class="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
          <section :if={@context} id="model-context-diagnostics">
            <h3 class="font-semibold text-neutral-700 dark:text-neutral-200">Model context</h3>
            <dl class="mt-1 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[0.7rem]">
              <dt class="text-neutral-400">model</dt>
              <dd class="break-all font-mono text-neutral-700 dark:text-neutral-300">
                {@context[:model_id] || "—"}
              </dd>
              <dt class="text-neutral-400">API</dt>
              <dd class="break-all font-mono text-neutral-700 dark:text-neutral-300">
                {@context[:api] || "—"}
              </dd>
              <dt class="text-neutral-400">window</dt>
              <dd class="break-all font-mono text-neutral-700 dark:text-neutral-300">
                {format_threshold(@context[:context_window])} · {source_label(
                  @context[:context_window_source]
                )}
              </dd>
            </dl>
          </section>

          <section :if={@workflow} id="workflow-diagnostics">
            <h3 class="font-semibold text-neutral-700 dark:text-neutral-200">Workflow</h3>
            <p class="mt-1 break-all font-mono text-[0.7rem] text-neutral-600 dark:text-neutral-300">
              {@workflow[:name]} · {inspect(@workflow[:module])}
            </p>
            <p class="mt-1 break-all text-[0.65rem] text-neutral-400 dark:text-neutral-500">
              {source_label(@workflow[:source])}
            </p>
          </section>

          <section :if={@prompt} id="prompt-diagnostics">
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <h3 class="font-semibold text-neutral-700 dark:text-neutral-200">
                {@prompt.label}
              </h3>
              <code id="prompt-digest" class="break-all font-mono text-[0.6rem] text-neutral-400">
                {@prompt.digest}
              </code>
            </div>
            <ol id="prompt-provenance" class="mt-2 space-y-1">
              <li
                :for={{source, index} <- Enum.with_index(@prompt.sources, 1)}
                class="flex gap-2 text-[0.65rem] text-neutral-500 dark:text-neutral-400"
              >
                <span class="font-mono text-neutral-300 dark:text-neutral-600">{index}.</span>
                <code class="break-all font-mono">{source_label(source)}</code>
              </li>
            </ol>
            <textarea
              id="resolved-prompt-text"
              readonly
              rows="10"
              class="mt-3 w-full resize-y whitespace-pre-wrap break-words rounded-xl border border-neutral-200 bg-neutral-50 p-3 font-mono text-[0.7rem] leading-5 text-neutral-700 outline-none dark:border-white/10 dark:bg-white/5 dark:text-neutral-300"
            >{@prompt.text}</textarea>
          </section>

          <p
            :if={match?({:error, _}, @preview) && is_nil(@prompt)}
            id="prompt-preview-error"
            class="text-amber-700 dark:text-amber-200"
          >
            Prompt preview is unavailable for this session.
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp diagnostic_prompt(%{run_metadata: %{prompt: %{} = prompt}}),
    do: Map.put(prompt, :label, "Resolved run prompt")

  defp diagnostic_prompt(%{prompt_preview: {:ok, %{} = prompt}}),
    do: Map.put(prompt, :label, "Selected-model prompt preview")

  defp diagnostic_prompt(_assigns), do: nil

  defp metadata_value(%{} = metadata, key), do: Map.get(metadata, key)
  defp metadata_value(_metadata, _key), do: nil

  defp short_cwd(cwd) when is_binary(cwd) do
    case Path.split(cwd) do
      parts when length(parts) > 3 -> "…/" <> (parts |> Enum.take(-2) |> Path.join())
      _parts -> cwd
    end
  end

  defp short_cwd(cwd), do: to_string(cwd)

  defp digest_prefix(digest) when is_binary(digest), do: String.slice(digest, 0, 8)
  defp digest_prefix(_digest), do: "unknown"

  defp source_label(nil), do: "default"
  defp source_label(source) when is_atom(source), do: Atom.to_string(source)
  defp source_label(source), do: inspect(source, limit: 20, printable_limit: 160)

  defp nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value), do: 0

  defp positive(value), do: Catalyst.Model.positive_int(value)

  defp format_tokens(tokens) when is_integer(tokens) and tokens >= 1_000,
    do: :erlang.float_to_binary(tokens / 1_000, decimals: 1) <> "k"

  defp format_tokens(tokens) when is_integer(tokens), do: Integer.to_string(tokens)

  defp format_threshold(nil), do: "none"
  defp format_threshold(value) when is_integer(value), do: format_tokens(value)
  defp format_threshold(value), do: to_string(value)

  defp boot_status_heading(status),
    do: status |> Catalyst.Extensions.describe_boot_status() |> elem(0)

  defp boot_status_reason(status),
    do: status |> Catalyst.Extensions.describe_boot_status() |> elem(1)

  defp upload_error_label(:too_large), do: "image too large (max 5MB)"
  defp upload_error_label(:not_accepted), do: "unsupported image type"
  defp upload_error_label(:too_many_files), do: "too many images (max 4)"
  defp upload_error_label(other), do: to_string(other)

  defp codex_select_class do
    "cursor-pointer rounded-full border border-neutral-200 bg-transparent px-2 py-1 text-xs " <>
      "font-medium text-neutral-600 outline-none transition hover:border-neutral-300 " <>
      "hover:text-neutral-900 focus:border-neutral-400 dark:border-white/10 " <>
      "dark:text-neutral-300 dark:hover:border-white/20 dark:hover:text-white"
  end

  defp fast_button_class(active?) do
    [
      "rounded-full border px-2.5 py-1 text-xs font-semibold transition",
      active? &&
        "border-amber-500/50 bg-amber-500/10 text-amber-700 dark:border-amber-400/40 dark:bg-amber-400/10 dark:text-amber-300",
      !active? &&
        "border-neutral-200 text-neutral-500 hover:border-neutral-300 hover:text-neutral-900 dark:border-white/10 dark:text-neutral-400 dark:hover:border-white/20 dark:hover:text-white"
    ]
  end

  defp quiet_button_class(active?) do
    [
      "flex items-center gap-1 rounded-full border px-2.5 py-1 text-xs font-semibold transition",
      active? &&
        "border-neutral-400 bg-neutral-200/70 text-neutral-900 dark:border-white/25 dark:bg-white/10 dark:text-white",
      !active? &&
        "border-neutral-200 text-neutral-500 hover:border-neutral-300 hover:text-neutral-900 dark:border-white/10 dark:text-neutral-400 dark:hover:border-white/20 dark:hover:text-white"
    ]
  end

  defp computer_button_class(active?) do
    [
      "flex items-center gap-1 rounded-full border px-2.5 py-1 text-xs font-semibold transition",
      active? &&
        "border-rose-500/50 bg-rose-500/10 text-rose-700 dark:border-rose-400/40 dark:bg-rose-400/10 dark:text-rose-300",
      !active? &&
        "border-neutral-200 text-neutral-500 hover:border-neutral-300 hover:text-neutral-900 dark:border-white/10 dark:text-neutral-400 dark:hover:border-white/20 dark:hover:text-white"
    ]
  end
end
