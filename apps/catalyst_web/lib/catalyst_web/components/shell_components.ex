defmodule CatalystWeb.ShellComponents do
  @moduledoc """
  Rendering for the persistent application shell around runtime-registered pages.

  The LiveView owns events and state transitions; this module owns shell chrome,
  Codex controls, extension recovery status, and delegation to the live UI
  registry. Keeping it stateless makes markup hot-swappable without moving
  process ownership out of `CatalystWeb.ShellLive`.
  """

  use CatalystWeb, :html

  alias Catalyst.LLM.OpenAICodex
  alias CatalystWeb.UI.{PageRenderer, Registry}

  @doc "Renders the complete shell around the currently selected page."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    catalog = OpenAICodex.catalog_snapshot(assigns.codex_prefs.model)

    assigns =
      assign(assigns,
        codex_catalog: catalog.models,
        codex_form: codex_form(assigns.codex_prefs),
        diagnostic_prompt: diagnostic_prompt(assigns),
        diagnostic_workflow: metadata_value(assigns.run_metadata, :workflow),
        diagnostic_context: metadata_value(assigns.run_metadata, :context),
        selected_codex_entry: catalog.selected,
        shell_pages: Registry.list_pages()
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
        <%!-- relative + z-40: the header must own a stacking context above the
          page content, or the absolutely-positioned diagnostics popover paints
          underneath later siblings (main renders after the header). --%>
        <header
          id="shell-header"
          class="relative z-40 flex min-h-12 items-center gap-3 border-b border-neutral-200 bg-neutral-50 px-3 dark:border-white/10 dark:bg-neutral-900"
        >
          <div class="flex min-w-0 flex-1 items-center gap-2">
            <span :if={@running} class="flex items-center gap-1" aria-label="Agent running">
              <span class="size-1.5 animate-pulse rounded-full bg-indigo-500"></span>
              <span class="size-1.5 animate-pulse rounded-full bg-indigo-500 delay-150"></span>
              <span class="size-1.5 animate-pulse rounded-full bg-indigo-500 delay-300"></span>
            </span>

            <nav :if={length(@shell_pages) > 1} id="shell-page-nav" class="flex items-center gap-1">
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

            <span
              class="ml-2 truncate font-mono text-xs text-neutral-400 dark:text-neutral-500"
              title="Working directory — change with /cd <path>"
            >
              {@cwd}
            </span>

            <.context_meter :if={@context_status} status={@context_status} />
            <.run_diagnostics
              prompt={@diagnostic_prompt}
              workflow={@diagnostic_workflow}
              context={@diagnostic_context}
              preview={@prompt_preview}
              open={@diagnostics_open}
            />
          </div>

          <div class="flex flex-none items-center gap-1.5">
            {PageRenderer.render_components(:header_extra, assigns)}

            <button
              id="quiet-toggle"
              type="button"
              phx-click="toggle_quiet"
              title="Quiet mode: hide tool calls/results and thinking (display only)"
              class={quiet_button_class(@ui_prefs.quiet)}
            >
              <.icon name="hero-eye-slash" class="size-3.5" /> Quiet
            </button>

            <div class="flex items-center gap-1.5">
              <.form
                for={@codex_form}
                id="codex-opts"
                phx-change="codex_opts"
                class="flex items-center gap-1.5"
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

            <button
              id="new-session-button"
              class="rounded-full px-3 py-1.5 text-xs font-medium text-neutral-500 transition hover:bg-neutral-200/60 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-white/10 dark:hover:text-white"
              phx-click="new_session"
              type="button"
            >
              New
            </button>
          </div>
        </header>

        <div
          :if={@boot_status != :ok}
          id="extension-boot-status"
          class="border-b border-amber-300/60 bg-amber-50 px-4 py-2 text-xs text-amber-900 dark:border-amber-400/30 dark:bg-amber-500/10 dark:text-amber-200"
        >
          ⚠ {boot_status_heading(@boot_status)} — {boot_status_reason(@boot_status)}. Recover from the
          <.link patch={~p"/extensions"} class="font-semibold underline">Extensions panel</.link>
          (disable or roll back the offender, then load again), or ask the agent to run <code class="font-mono">reload_extensions</code>.
        </div>

        {PageRenderer.render(assigns)}
      </div>
    </Layouts.app>
    """
  end

  defp codex_form(prefs) do
    to_form(%{
      "model" => prefs.model,
      "effort" => prefs.effort,
      "transport" => prefs.transport
    })
  end

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
      class="ml-2 hidden min-w-40 items-center gap-2 rounded-full border border-neutral-200 px-2.5 py-1 text-[0.65rem] text-neutral-500 sm:flex dark:border-white/10 dark:text-neutral-400"
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
        class="h-1.5 w-16 overflow-hidden rounded-full accent-indigo-500"
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
        class="max-w-24 truncate text-neutral-400 dark:text-neutral-500"
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
      class="group relative ml-1 hidden md:block"
    >
      <button
        id="run-diagnostics-toggle"
        type="button"
        phx-click="toggle_diagnostics"
        aria-expanded={to_string(@open)}
        aria-controls="run-diagnostics-panel"
        class="flex cursor-pointer items-center gap-1 rounded-full border border-neutral-200 px-2.5 py-1 text-[0.65rem] font-medium text-neutral-500 transition hover:border-neutral-300 hover:text-neutral-900 dark:border-white/10 dark:text-neutral-400 dark:hover:border-white/20 dark:hover:text-white"
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
        id="run-diagnostics-panel"
        class="absolute left-0 top-[calc(100%+0.5rem)] z-50 w-[min(38rem,calc(100vw-2rem))] overflow-hidden rounded-xl border border-neutral-200 bg-white text-xs shadow-xl shadow-neutral-950/10 dark:border-white/10 dark:bg-neutral-800 dark:shadow-black/40"
      >
        <div class="border-b border-neutral-200/70 px-4 py-3 dark:border-white/10">
          <p class="font-semibold text-neutral-900 dark:text-white">Run diagnostics</p>
          <p class="mt-0.5 text-[0.65rem] text-neutral-400 dark:text-neutral-500">
            Read-only resolution data; it is never reused as configuration.
          </p>
        </div>

        <div class="max-h-[70vh] space-y-4 overflow-y-auto p-4">
          <section :if={@context} id="model-context-diagnostics">
            <h3 class="font-semibold text-neutral-700 dark:text-neutral-200">Model context</h3>
            <dl class="mt-1 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[0.7rem]">
              <dt class="text-neutral-400">model</dt>
              <dd class="font-mono text-neutral-700 dark:text-neutral-300">
                {@context[:model_id] || "—"}
              </dd>
              <dt class="text-neutral-400">API</dt>
              <dd class="font-mono text-neutral-700 dark:text-neutral-300">
                {@context[:api] || "—"}
              </dd>
              <dt class="text-neutral-400">window</dt>
              <dd class="font-mono text-neutral-700 dark:text-neutral-300">
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
              class="mt-3 w-full resize-y rounded-xl border border-neutral-200 bg-neutral-50 p-3 font-mono text-[0.7rem] leading-5 text-neutral-700 outline-none dark:border-white/10 dark:bg-white/5 dark:text-neutral-300"
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

  defp digest_prefix(digest) when is_binary(digest), do: String.slice(digest, 0, 8)
  defp digest_prefix(_digest), do: "unknown"

  defp source_label(nil), do: "default"
  defp source_label(source) when is_atom(source), do: Atom.to_string(source)
  defp source_label(source), do: inspect(source, limit: 20, printable_limit: 160)

  defp nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value), do: 0

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil

  defp format_tokens(tokens) when is_integer(tokens) and tokens >= 1_000,
    do: :erlang.float_to_binary(tokens / 1_000, decimals: 1) <> "k"

  defp format_tokens(tokens) when is_integer(tokens), do: Integer.to_string(tokens)

  defp format_threshold(nil), do: "none"
  defp format_threshold(value) when is_integer(value), do: format_tokens(value)
  defp format_threshold(value), do: to_string(value)

  defp boot_status_heading({:load_failed, _reason}), do: "Extension boot load failed"
  defp boot_status_heading(_status), do: "Extensions were not loaded"

  defp boot_status_reason({:safe_mode, :env}), do: "CATALYST_SAFE_MODE is set"

  defp boot_status_reason({:safe_mode, :crash_detected}) do
    "the previous boot crashed while extensions were active"
  end

  defp boot_status_reason({:load_failed, reason}) do
    "the boot-time load failed: #{Catalyst.Extensions.format_error(reason)}"
  end

  defp boot_status_reason(_status), do: "safe mode"

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
end
