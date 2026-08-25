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
        diagnostic_prompt: diagnostic_prompt(assigns),
        diagnostic_workflow: metadata_value(assigns.run_metadata, :workflow),
        diagnostic_context: metadata_value(assigns.run_metadata, :context)
      )

    ~H"""
    <Layouts.app flash={@flash} class="min-h-screen bg-bg text-ink antialiased">
      <div
        id="catalyst-shell"
        data-session-id={@session_id || ""}
        class="flex h-screen flex-col bg-bg text-ink"
      >
        <header
          id="shell-header"
          class="relative z-40 flex h-9 shrink-0 items-center gap-1.5 border-b border-edge bg-bg px-2"
        >
          <button
            id="sidebar-toggle"
            type="button"
            phx-click="toggle_sidebar"
            aria-pressed={to_string(@ui_prefs.sidebar)}
            aria-controls="shell-sidebar"
            title={if(@ui_prefs.sidebar, do: "Hide sidebar", else: "Show sidebar")}
            class="flex size-7 shrink-0 items-center justify-center rounded-md text-muted transition hover:bg-raised hover:text-ink"
          >
            <.icon name="hero-bars-3" class="size-3.5" />
          </button>

          <span :if={@running} class="flex items-center gap-0.5" aria-label="Agent running">
            <span class="size-1 animate-pulse rounded-full bg-accent"></span>
            <span class="size-1 animate-pulse rounded-full bg-accent delay-150"></span>
            <span class="size-1 animate-pulse rounded-full bg-accent delay-300"></span>
          </span>

          <nav
            :if={length(@shell_pages) > 1}
            id="shell-page-nav"
            class="flex min-w-0 items-center gap-0.5"
          >
            <.link
              :for={page <- @shell_pages}
              id={"page-nav-#{page.path}"}
              patch={~p"/#{page.path}"}
              class={[
                "rounded-md px-2 py-0.5 text-[11px] font-medium transition",
                @page == page.path && "bg-raised text-ink",
                @page != page.path && "text-muted hover:bg-raised hover:text-ink"
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
                class="rounded-full p-2 text-muted transition hover:bg-raised hover:text-ink"
                phx-click="logout"
                title={"Sign out of #{subscription_name(@selected_codex_entry)}"}
                type="button"
              >
                <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
              </button>
            <% else %>
              <button
                :if={@login_state != :pending}
                id="login-button"
                class="rounded-md bg-accent px-2 py-1 text-[11px] font-semibold text-white transition hover:bg-accent/90"
                phx-click="login"
                type="button"
              >
                Sign in to {subscription_name(@selected_codex_entry)}
              </button>
              <span
                :if={@login_state == :pending}
                id="login-pending"
                class="flex items-center gap-2 text-xs text-muted"
              >
                <span class="size-3 animate-spin rounded-full border-2 border-edge border-t-muted"></span>
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
              class="relative z-30 shrink-0 border-t border-edge bg-bg"
            >
              <.run_bar
                cwd={@cwd}
                running={@running}
                context_status={@context_status}
                diagnostic_prompt={@diagnostic_prompt}
                diagnostic_workflow={@diagnostic_workflow}
                diagnostic_context={@diagnostic_context}
                prompt_preview={@prompt_preview}
                diagnostics_open={@diagnostics_open}
                ui_prefs={@ui_prefs}
                codex_form={@codex_form}
                codex_catalog={@codex_catalog}
                selected_codex_entry={@selected_codex_entry}
                codex_prefs={@codex_prefs}
                chrome_menu={@chrome_menu}
                root={assigns}
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
      class="flex w-52 shrink-0 flex-col overflow-y-auto border-r border-edge bg-bg"
    >
      {PageRenderer.render_components(:sidebar, @root)}

      <section id="sidebar-projects" class="px-1.5 py-2">
        <div class="mb-1 flex items-center gap-1 px-1.5">
          <p class="min-w-0 flex-1 truncate text-[10px] text-faint">Projects</p>
          <button
            id="sidebar-new-thread"
            type="button"
            phx-click="new_session"
            title="New thread"
            class="rounded p-0.5 text-faint transition hover:bg-raised hover:text-ink"
          >
            <.icon name="hero-plus" class="size-3" />
          </button>
        </div>

        <p :if={@sidebar.projects == []} class="px-1.5 py-2 text-[11px] text-faint">
          No threads yet
        </p>

        <div :for={project <- @sidebar.projects} id={project.id} class="mb-0.5">
          <div class="group flex items-center gap-1 px-1.5 py-0.5">
            <.icon name="hero-folder" class="size-3 shrink-0 text-faint" />
            <span class="min-w-0 flex-1 truncate text-[11px] font-medium text-muted">
              {project.label}
            </span>
            <button
              id={"project-new-thread-#{project.id}"}
              type="button"
              phx-click="new_session_in"
              phx-value-cwd={project.cwd}
              title="New thread"
              class="rounded p-0.5 text-faint opacity-0 transition hover:bg-raised hover:text-ink group-hover:opacity-100"
            >
              <.icon name="hero-plus" class="size-3" />
            </button>
          </div>

          <div
            :for={thread <- project.threads}
            id={"thread-#{thread.id}"}
            class={[
              "group flex items-center gap-0.5 rounded-md py-px pl-5 pr-0.5",
              thread.current? && "bg-raised",
              !thread.current? && "hover:bg-raised"
            ]}
          >
            <button
              id={"switch-thread-#{thread.id}"}
              type="button"
              phx-click="switch_session"
              phx-value-id={thread.id}
              class={[
                "flex min-w-0 flex-1 items-center gap-1.5 rounded px-1 py-0.5 text-left text-[11px] transition",
                thread.current? && "text-ink",
                !thread.current? && "text-muted hover:text-ink"
              ]}
            >
              <span class={[
                "size-1 shrink-0 rounded-full",
                thread.live? && "bg-ok/80",
                !thread.live? && "bg-edge-strong"
              ]}></span>
              <span class="min-w-0 truncate">{thread.title}</span>
            </button>
            <button
              id={"close-thread-#{thread.id}"}
              type="button"
              phx-click="close_session"
              phx-value-id={thread.id}
              title="Close thread"
              class="rounded p-0.5 text-faint opacity-0 transition hover:bg-raised hover:text-ink group-hover:opacity-100"
            >
              <.icon name="hero-x-mark" class="size-2.5" />
            </button>
          </div>
        </div>
      </section>
    </aside>
    """
  end

  attr :file_search, :any, default: nil

  @doc "File-search dropdown shown above the inline draft."
  def file_search_popover(assigns) do
    ~H"""
    <div
      :if={@file_search}
      id="file-search-results"
      class="mb-2 rounded-lg border border-edge bg-surface px-3 py-2"
    >
      <div>
        <p class="text-[0.65rem] font-semibold uppercase tracking-wide text-faint">
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
            class="flex items-baseline gap-3 rounded-lg px-2 py-1 text-left text-xs transition hover:bg-raised"
          >
            <code class="shrink-0 font-mono font-semibold text-ink">
              {r.label}
            </code>
            <span class="truncate font-mono text-faint">{r.path}</span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Inline transcript draft. Enter sends or queues; Shift+Enter is a newline.

  Deliberately invisible (no box, no buttons): the draft is just the tail of
  the transcript, Delta-style. Send is the Enter key (or `#run-send` in the
  footer run bar); Stop lives in the run bar as `#run-stop`.
  """
  def composer(assigns) do
    ~H"""
    <.form
      for={@chat_form}
      id="chat-form"
      phx-submit="send"
      phx-change="typing"
      phx-hook="PasteImages"
      class="mt-2"
    >
      <div id="composer-shell">
        <div :if={@uploads.image.entries != []} class="mb-2 flex flex-wrap items-center gap-2">
          <div :for={entry <- @uploads.image.entries} class="relative" data-image-entry>
            <.live_img_preview
              entry={entry}
              class="h-16 w-16 rounded-lg border border-edge object-cover"
            />
            <button
              type="button"
              phx-click="cancel_image"
              phx-value-ref={entry.ref}
              aria-label="remove image"
              class="absolute -right-1.5 -top-1.5 flex size-5 items-center justify-center rounded-full border border-edge bg-surface text-xs text-muted shadow transition hover:border-edge-strong hover:text-ink"
            >
              ×
            </button>
            <span
              :if={not entry.done?}
              class="absolute inset-x-0 bottom-0 rounded-b-lg bg-surface/80 text-center text-[0.6rem] text-ink"
            >
              {entry.progress}%
            </span>
            <p :for={err <- upload_errors(@uploads.image, entry)} class="text-xs text-danger">
              {upload_error_label(err)}
            </p>
          </div>
          <p :for={err <- upload_errors(@uploads.image)} class="text-xs text-danger">
            {upload_error_label(err)}
          </p>
        </div>

        <.input
          field={@chat_form[:message]}
          type="textarea"
          id="chat-input"
          autocomplete="off"
          phx-debounce="150"
          phx-hook="ChatSubmit"
          rows="1"
          placeholder="Ask Catalyst…"
          container_class="m-0 min-w-0"
          class="w-full resize-none border-0 bg-transparent px-0 py-1 text-sm leading-7 text-ink outline-none placeholder:text-faint focus:ring-0"
        />
        <.live_file_input upload={@uploads.image} class="hidden" />
      </div>
    </.form>
    """
  end

  defp run_bar(assigns) do
    ~H"""
    <div id="shell-run-bar" class="flex w-full items-center gap-1 px-2 py-1">
      <div id="shell-header-status" class="flex min-w-0 items-center gap-1">
        <.icon name="hero-folder" class="size-3 shrink-0 text-faint" />
        <span
          id="header-cwd"
          class="min-w-0 truncate font-mono text-[11px] text-faint"
          title={"#{@cwd} — change with /cd <path>"}
        >
          {short_cwd(@cwd)}
        </span>
        <button
          id="new-session-button"
          class="flex size-6 items-center justify-center rounded-md text-faint transition hover:bg-raised hover:text-ink"
          phx-click="new_session"
          type="button"
          title="New thread"
        >
          <.icon name="hero-plus" class="size-3" />
        </button>
        <.context_meter :if={@context_status} status={@context_status} />
      </div>

      <div
        id="shell-header-controls"
        class="ml-auto flex min-w-0 items-center justify-end gap-0.5"
      >
        <button
          id="quiet-toggle"
          type="button"
          phx-click="toggle_quiet"
          aria-pressed={to_string(@ui_prefs.quiet)}
          title="Quiet mode: hide tool calls/results and thinking (display only)"
          class={icon_btn_class(@ui_prefs.quiet)}
        >
          <.icon name="hero-eye-slash" class="size-3.5" />
        </button>

        {PageRenderer.render_components(:run_controls, @root)}

        <div id="codex-control-group" class="flex min-w-0 items-center gap-0.5">
          <.form for={@codex_form} id="codex-opts" phx-change="codex_opts" class="sr-only">
            <.input
              field={@codex_form[:model]}
              type="select"
              options={Enum.map(@codex_catalog, &{&1.name, &1.id})}
              container_class="m-0"
              class={codex_select_class()}
              title="Model"
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

          <.chrome_menu
            id="codex-model-menu"
            menu="model"
            open?={@chrome_menu == :model}
            label={@selected_codex_entry.name}
            title="Model"
          >
            <button
              :for={entry <- @codex_catalog}
              id={"codex-model-#{entry.id}"}
              type="button"
              phx-click="codex_opts"
              phx-value-model={entry.id}
              class={menu_item_class(entry.id == @codex_prefs.model)}
            >
              {entry.name}
            </button>
          </.chrome_menu>

          <.chrome_menu
            id="codex-effort-menu"
            menu="effort"
            open?={@chrome_menu == :effort}
            label={@codex_prefs.effort}
            title="Reasoning effort"
          >
            <button
              :for={effort <- @selected_codex_entry.efforts}
              id={"codex-effort-#{effort}"}
              type="button"
              phx-click="codex_opts"
              phx-value-effort={effort}
              class={menu_item_class(effort == @codex_prefs.effort)}
            >
              {effort}
            </button>
          </.chrome_menu>

          <button
            :if={@selected_codex_entry.fast?}
            id="codex-fast-toggle"
            type="button"
            phx-click="codex_fast"
            aria-pressed={to_string(@codex_prefs.fast)}
            title="Fast mode (priority service tier): ~1.5x speed, increased usage"
            class={icon_btn_class(@codex_prefs.fast, :fast)}
          >
            <span class="text-[11px] leading-none">⚡</span>
          </button>
        </div>

        <.run_diagnostics
          prompt={@diagnostic_prompt}
          workflow={@diagnostic_workflow}
          context={@diagnostic_context}
          preview={@prompt_preview}
          open={@diagnostics_open}
        />

        <%!-- Run control, Delta-style: the composer has no buttons, so send
          lives here (Enter still submits) and stop replaces it while a run
          is active. SubmitChat's #run-send click submits #chat-form. --%>
        <button
          :if={@running}
          id="run-stop"
          type="button"
          phx-click="abort"
          aria-label="Stop"
          title="Stop the run"
          class="flex size-6 shrink-0 items-center justify-center rounded-md text-danger transition hover:bg-danger/10"
        >
          <.icon name="hero-stop-solid" class="size-3.5" />
        </button>
        <button
          :if={!@running}
          id="run-send"
          type="button"
          phx-hook="SubmitChat"
          aria-label="Send"
          title="Send (Enter)"
          class="flex size-6 shrink-0 items-center justify-center rounded-md text-muted transition hover:bg-raised hover:text-accent"
        >
          <.icon name="hero-paper-airplane" class="size-3.5" />
        </button>
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

  defp subscription_name(%{auth_label: label}), do: label
  defp subscription_name(_entry), do: "Subscription"

  attr :id, :string, required: true
  attr :menu, :string, required: true
  attr :open?, :boolean, required: true
  attr :label, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp chrome_menu(assigns) do
    ~H"""
    <div class="relative">
      <button
        id={"#{@id}-toggle"}
        type="button"
        phx-click="toggle_chrome_menu"
        phx-value-menu={@menu}
        aria-expanded={to_string(@open?)}
        aria-controls={"#{@id}-panel"}
        title={@title}
        class={[
          "flex max-w-28 items-center truncate rounded-md px-1.5 py-1 text-[11px] text-muted transition hover:bg-raised hover:text-ink",
          @open? && "bg-raised text-ink"
        ]}
      >
        {@label}
      </button>

      <div
        :if={@open?}
        id={"#{@id}-backdrop"}
        class="fixed inset-0 z-40"
        phx-click="close_chrome_menu"
      >
      </div>

      <div
        :if={@open?}
        id={"#{@id}-panel"}
        phx-window-keydown="close_chrome_menu"
        phx-key="Escape"
        class="absolute bottom-full right-0 z-50 mb-1 max-h-64 min-w-44 overflow-y-auto rounded-lg border border-edge bg-surface py-1 shadow-lg"
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp diagnostics_title(%{prompt: %{digest: digest}}), do: "Prompt " <> digest_prefix(digest)
  defp diagnostics_title(%{preview: :loading}), do: "Resolving prompt…"
  defp diagnostics_title(_assigns), do: "Run details"

  attr :status, :map, required: true

  defp context_meter(assigns) do
    used = nonnegative(assigns.status[:used_tokens])
    threshold = positive(assigns.status[:threshold])

    assigns =
      assign(assigns,
        used: used,
        threshold: threshold,
        source_label: source_label(assigns.status[:threshold_source])
      )

    ~H"""
    <div
      id="context-meter"
      class="hidden shrink-0 items-center gap-1 whitespace-nowrap text-[10px] text-faint sm:flex"
      title={"Context threshold source: #{@source_label}"}
    >
      <.icon name="hero-circle-stack-micro" class="size-3.5 shrink-0 text-faint" />
      <progress
        :if={@threshold}
        id="context-progress"
        value={min(@used, @threshold)}
        max={@threshold}
        class="hidden h-1.5 w-16 overflow-hidden rounded-full accent-accent xl:block"
      >
        {@used} / {@threshold}
      </progress>
      <span id="context-token-count" class="whitespace-nowrap font-mono">
        {format_tokens(@used)} / {format_threshold(@threshold)}
      </span>
      <span
        id="context-estimate-state"
        class="font-medium text-muted"
      >
        estimated
      </span>
      <span id="context-threshold-source" class="hidden max-w-24 truncate text-faint xl:inline">
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
        class={icon_btn_class(@open)}
        title={diagnostics_title(assigns)}
      >
        <.icon name="hero-document-text-micro" class="size-3.5" />
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
        class="fixed bottom-16 right-4 z-50 flex max-h-[min(70vh,36rem)] w-[min(38rem,calc(100vw-2rem))] flex-col overflow-hidden rounded-xl border border-edge bg-surface text-xs shadow-lg"
      >
        <div class="shrink-0 border-b border-edge px-4 py-3">
          <p class="font-semibold text-ink">Run diagnostics</p>
          <p class="mt-0.5 text-[0.65rem] leading-4 text-faint">
            Read-only resolution data; it is never reused as configuration.
          </p>
        </div>

        <div class="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
          <section :if={@context} id="model-context-diagnostics">
            <h3 class="font-semibold text-ink">Model context</h3>
            <dl class="mt-1 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[0.7rem]">
              <dt class="text-faint">model</dt>
              <dd class="break-all font-mono text-muted">
                {@context[:model_id] || "—"}
              </dd>
              <dt class="text-faint">API</dt>
              <dd class="break-all font-mono text-muted">
                {@context[:api] || "—"}
              </dd>
              <dt class="text-faint">window</dt>
              <dd class="break-all font-mono text-muted">
                {format_threshold(@context[:context_window])} · {source_label(
                  @context[:context_window_source]
                )}
              </dd>
            </dl>
          </section>

          <section :if={@workflow} id="workflow-diagnostics">
            <h3 class="font-semibold text-ink">Workflow</h3>
            <p class="mt-1 break-all font-mono text-[0.7rem] text-muted">
              {@workflow[:name]} · {inspect(@workflow[:module])}
            </p>
            <p class="mt-1 break-all text-[0.65rem] text-faint">
              {source_label(@workflow[:source])}
            </p>
          </section>

          <section :if={@prompt} id="prompt-diagnostics">
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <h3 class="font-semibold text-ink">
                {@prompt.label}
              </h3>
              <code id="prompt-digest" class="break-all font-mono text-[0.6rem] text-faint">
                {@prompt.digest}
              </code>
            </div>
            <ol id="prompt-provenance" class="mt-2 space-y-1">
              <li
                :for={{source, index} <- Enum.with_index(@prompt.sources, 1)}
                class="flex gap-2 text-[0.65rem] text-muted"
              >
                <span class="font-mono text-faint">{index}.</span>
                <code class="break-all font-mono">{source_label(source)}</code>
              </li>
            </ol>
            <textarea
              id="resolved-prompt-text"
              readonly
              rows="10"
              class="mt-3 w-full resize-y whitespace-pre-wrap break-words rounded-xl border border-edge bg-raised p-3 font-mono text-[0.7rem] leading-5 text-muted outline-none"
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
    "cursor-pointer rounded-full border border-edge bg-transparent px-2 py-1 text-xs " <>
      "font-medium text-muted outline-none transition hover:border-edge-strong " <>
      "hover:text-ink focus:border-accent"
  end

  defp icon_btn_class(active?, kind \\ :default) do
    [
      "flex size-7 items-center justify-center rounded-md transition",
      !active? && "text-muted hover:bg-raised hover:text-ink",
      active? && kind == :default && "bg-raised text-ink",
      # Amber is the accepted second hue for "fast mode" — kept out of the token
      # palette on purpose, so it stays a `dark:` pair.
      active? && kind == :fast &&
        "bg-amber-500/10 text-amber-700 dark:bg-amber-400/10 dark:text-amber-300"
    ]
  end

  defp menu_item_class(selected?) do
    [
      "flex w-full px-3 py-1 text-left text-[11px] transition",
      selected? && "bg-raised text-ink",
      !selected? && "text-muted hover:bg-raised hover:text-ink"
    ]
  end
end
