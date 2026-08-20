defmodule CatalystWeb.Pages.ComputerPage do
  @moduledoc """
  The computer-use panel — registered as the `"computer"` page in
  `CatalystWeb.UI.Registry` (a built-in page, exactly like `Pages.ExtensionsPage`;
  routing is catch-all, so no router change is involved).

  Always reported: whether the session grants computer use (the header toggle
  writes the same preference), and whether this machine can run the backend at
  all (`Catalyst.Tools.Computer.Availability`). Both must hold before any tool
  is advertised, so a page saying "on" while the backend is missing would be a
  lie — the states are shown together.

  Render-only: the toggle button emits the shell's `toggle_computer_use` event
  and the Refresh button emits `refresh_computer_state`, both handled by
  `CatalystWeb.ShellLive`.

  When (and only when) the backend is available, the page also reports the
  permission state per TCC subject: Accessibility from the backend's `grants/0`
  (the helper answers for itself — it IS the process that posts synthetic
  input; read-only preflight ops only, never the `request_*` prompting
  variants), Screen Recording from the backend's `capture_grant/0` (probed from
  the capture path — on macOS, `screencapture` runs as a child of the BEAM, a
  DIFFERENT TCC subject than the helper, so the helper's own preflight cannot
  answer for screenshots), plus helper Port liveness and a screens/windows
  preview.

  **Backend state is queried on navigation and on explicit Refresh, never
  during render — and never inside a LiveView callback.** `ShellLive` assigns
  the cheap `pending_state/0` immediately and computes `backend_state/0` in a
  `start_async/3` task (each helper op carries a 10s call budget, so a
  wedged-but-alive helper must not freeze the shell); the result lands in the
  `:computer_panel` assign and `render/1` reads only assigns. Unrelated
  re-renders while the page is open reuse the cached snapshot — a backend
  query there would mean synchronous helper round-trips per streamed token.
  Querying only on navigation/Refresh also keeps the lazy property: nothing is
  asked at boot, and nothing is queried when the backend is unavailable.
  """
  use CatalystWeb, :html

  alias Catalyst.Tools.Computer.{Availability, Backend, Helper}

  @settings_urls %{
    "accessibility" =>
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
    "screen_recording" =>
      "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
  }

  @doc """
  Resolve a permission pane key to its System Settings deep link.

  The `x-apple.systempreferences:` scheme cannot be navigated to from the
  desktop wxWebView (it only speaks http/https and errors with "unsupported
  URL"), so the page sends a pane *key* to `ShellLive`, which resolves it here
  and hands the URL to `open(1)` server-side — the event can never carry an
  arbitrary string into a shell.
  """
  @spec settings_url(String.t()) :: {:ok, String.t()} | :error
  def settings_url(pane), do: Map.fetch(@settings_urls, pane)

  @typedoc """
  The render-ready `/computer` snapshot. Queried fields are `:pending` while
  the async fetch started by `ShellLive` is still in flight, `:unavailable`
  when the backend cannot run here, and result tuples once resolved.
  """
  @type snapshot :: %{
          available?: boolean(),
          status: Availability.status(),
          headline: String.t(),
          detail: String.t(),
          helper_path: String.t(),
          helper_port: :open | :closed,
          grants:
            {:ok, %{accessibility: boolean(), screen_recording: boolean()}}
            | {:error, term()}
            | :unavailable
            | :pending,
          capture_grant: {:ok, boolean()} | {:error, term()} | :unavailable | :pending,
          screens: {:ok, [map()]} | {:error, term()} | :unavailable | :pending,
          windows: {:ok, [map()]} | {:error, term()} | :unavailable | :pending
        }

  @doc """
  The backend's availability as render-ready data — the full, resolved snapshot.

  Costs up to five synchronous backend round-trips, so `ShellLive` runs it in a
  `start_async/3` task on navigation to `/computer` and on the page's Refresh
  event — never inside a LiveView callback and never from `render/1` (see the
  moduledoc). Kept public so tests can assert the state without going through
  the DOM.
  """
  @spec backend_state() :: snapshot()
  def backend_state do
    status = Availability.status()
    backend = Backend.select()

    # Grants first (may lazily start the helper), then liveness reflects it.
    grants = query(status, fn -> backend.grants() end)

    Map.merge(base_state(status), %{
      grants: grants,
      capture_grant: query(status, fn -> backend.capture_grant() end),
      screens: query(status, fn -> backend.screens() end),
      windows: query(status, fn -> backend.windows() end),
      helper_port: helper_port(status)
    })
  end

  @doc """
  The cheap, immediately-assignable part of the snapshot: availability (app env
  plus a few `File.stat/2` calls) with every queried field `:pending` — or
  `:unavailable` when the backend cannot run, in which case nothing will be
  queried at all. Never touches the helper.
  """
  @spec pending_state() :: snapshot()
  def pending_state do
    status = Availability.status()
    Map.merge(base_state(status), pending_queries(status))
  end

  @doc "The snapshot rendered when the async fetch crashed: every query errored."
  @spec failed_state(term()) :: snapshot()
  def failed_state(reason) do
    status = Availability.status()
    error = {:error, {:snapshot_crashed, reason}}

    Map.merge(base_state(status), %{
      grants: error,
      capture_grant: error,
      screens: error,
      windows: error
    })
  end

  defp base_state(status) do
    {headline, detail} = describe(status)

    %{
      available?: status == :ok,
      status: status,
      headline: headline,
      detail: detail,
      helper_path: Availability.helper_path(),
      helper_port: helper_port(status)
    }
  end

  defp pending_queries(:ok),
    do: %{grants: :pending, capture_grant: :pending, screens: :pending, windows: :pending}

  defp pending_queries(_unavailable),
    do: %{
      grants: :unavailable,
      capture_grant: :unavailable,
      screens: :unavailable,
      windows: :unavailable
    }

  # Helper-backed state is queried only when the backend is available and the
  # page is actually being viewed — never at boot, and only through the
  # read-only preflight ops (the request_* prompting variants are never used).
  defp query(:ok, fun), do: fun.()
  defp query(_unavailable, _fun), do: :unavailable

  defp helper_port(:ok), do: Helper.status().port
  defp helper_port(_unavailable), do: :closed

  defp describe(:ok),
    do: {"Backend ready", "The native input helper was found and this is a supported platform."}

  defp describe({:error, :unsupported_platform}),
    do:
      {"No backend — unsupported platform",
       "Computer use is macOS-only. The tools are not advertised on this host."}

  defp describe({:error, :helper_missing}),
    do:
      {"No backend — helper binary missing",
       "The native input helper has not been built into this installation, so the tools are not advertised."}

  # ---- render -----------------------------------------------------------------

  def render(assigns) do
    # Reads the cached snapshot only — no backend query on re-render. ShellLive
    # assigns :computer_panel on navigation and on refresh_computer_state.
    ~H"""
    <main id="computer-page" class="flex-1 overflow-y-auto px-4 py-6 sm:px-6">
      <div class="mx-auto flex max-w-3xl flex-col gap-5">
        <.grant_card machine_prefs={@machine_prefs} backend={@computer_panel} />
        <.backend_card backend={@computer_panel} />
        <.permissions_card :if={@computer_panel.available?} backend={@computer_panel} />
        <.preview_card :if={@computer_panel.available?} backend={@computer_panel} />
        <.posture_card />
      </div>
    </main>
    """
  end

  attr :machine_prefs, :map, required: true
  attr :backend, :map, required: true

  defp grant_card(assigns) do
    ~H"""
    <div class={card_class()}>
      <div class="flex flex-wrap items-center gap-3 px-4 py-3">
        <div class="min-w-0 flex-1">
          <h1 class="text-base font-semibold text-ink">Computer use</h1>
          <p class="mt-0.5 text-xs text-muted">
            Let the agent see the screen and drive this machine the way you do.
          </p>
        </div>

        <span
          id="computer-grant-state"
          data-granted={to_string(@machine_prefs.computer_use and @backend.available?)}
          data-toggle={to_string(@machine_prefs.computer_use)}
          class={state_pill_class(@machine_prefs.computer_use and @backend.available?)}
        >
          {grant_label(@machine_prefs.computer_use, @backend.available?)}
        </span>

        <button
          id="computer-page-toggle"
          type="button"
          phx-click="toggle_computer_use"
          class={pill_button_class()}
        >
          {toggle_label(@machine_prefs.computer_use)}
        </button>
      </div>

      <p class="border-t border-edge px-4 py-2.5 text-xs leading-5 text-muted">
        The grant applies to the session's next run and is never inherited by subagents. Turning it
        on advertises the computer-use tools; turning it off removes them entirely, so they cost no
        tokens while the toggle is off.
      </p>
    </div>
    """
  end

  attr :backend, :map, required: true

  defp backend_card(assigns) do
    ~H"""
    <section id="computer-backend-status">
      <.section_title>Backend</.section_title>
      <div class={card_class()}>
        <div class="flex flex-wrap items-center gap-3 px-4 py-3">
          <span
            data-backend-status={backend_status_key(@backend.status)}
            class={state_pill_class(@backend.available?)}
          >
            {@backend.headline}
          </span>
          <p class="min-w-0 flex-1 text-xs leading-5 text-muted">
            {@backend.detail}
          </p>
          <button
            id="computer-refresh"
            type="button"
            phx-click="refresh_computer_state"
            title="Re-query the backend, permissions, and previews"
            class={pill_button_class()}
          >
            Refresh
          </button>
        </div>
        <div class="grid gap-1 border-t border-edge px-4 py-2.5 text-xs sm:grid-cols-[10rem_1fr]">
          <span class="font-medium text-muted">helper binary</span>
          <code id="computer-helper-path" class="break-all font-mono text-ink">
            {@backend.helper_path}
          </code>
          <span class="font-medium text-muted">helper process</span>
          <span
            id="computer-helper-liveness"
            data-helper-port={Atom.to_string(@backend.helper_port)}
            class="text-ink"
          >
            {helper_liveness_label(@backend.helper_port)}
          </span>
        </div>
      </div>
    </section>
    """
  end

  attr :backend, :map, required: true

  # The two rows deliberately come from two different sources because they
  # describe two different TCC subjects: Accessibility from `grants/0` (the
  # helper answers for itself, and the helper is what posts synthetic input),
  # Screen Recording from `capture_grant/0` (probed from the process that
  # actually runs `screencapture` — the helper's own preflight cannot answer
  # for it, and the two can genuinely disagree).
  defp permissions_card(assigns) do
    ~H"""
    <section id="computer-permissions">
      <.section_title>Permissions</.section_title>
      <div class={card_class()}>
        <%= case @backend.grants do %>
          <% {:ok, grants} -> %>
            <.permission_row
              id="computer-grant-accessibility"
              name="Accessibility"
              granted={grants.accessibility}
              pane="accessibility"
              detail="Required to post synthetic mouse and keyboard input. Answers for the native helper process — the process that posts the input."
            />
          <% {:error, reason} -> %>
            <p
              id="computer-grants-error"
              class="px-4 py-3 text-xs leading-5 text-muted"
            >
              Permission state is unavailable: <code class="font-mono">{inspect(reason)}</code>.
              The helper answers for its own TCC grants, so it must be present and runnable.
            </p>
          <% :pending -> %>
            <p
              id="computer-grants-pending"
              class="px-4 py-3 text-xs leading-5 text-muted"
            >
              Checking permission state…
            </p>
          <% _unavailable -> %>
            <p class="px-4 py-3 text-xs leading-5 text-muted">
              Permission state is reported once the backend is available.
            </p>
        <% end %>
        <%= case @backend.capture_grant do %>
          <% {:ok, granted} -> %>
            <.permission_row
              id="computer-grant-screen-recording"
              name="Screen Recording"
              granted={granted}
              pane="screen_recording"
              detail="Required for screenshots to see other apps' windows. Probed from the app process that runs screencapture — a different TCC subject than the helper above."
            />
          <% {:error, reason} -> %>
            <p
              id="computer-capture-grant-error"
              class="px-4 py-3 text-xs leading-5 text-muted"
            >
              Screenshot readiness is unavailable: <code class="font-mono">{inspect(reason)}</code>.
            </p>
          <% _pending_or_unavailable -> %>
            <%!-- The grants clause above already renders the card's pending /
                 unavailable copy; both fields resolve in the same fetch. --%>
        <% end %>
        <p class="border-t border-edge px-4 py-2.5 text-xs leading-5 text-faint">
          Input grants attach to the helper binary's code signature — rebuilding the helper changes
          its ad-hoc signature, which can silently invalidate a grant; remove and re-add the entry
          in System Settings when that happens. The Screen Recording grant belongs to the app that
          hosts Catalyst (it spawns screencapture), not to the helper.
        </p>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :granted, :boolean, required: true
  attr :pane, :string, required: true
  attr :detail, :string, required: true

  defp permission_row(assigns) do
    ~H"""
    <div
      id={@id}
      data-granted={to_string(@granted)}
      class="flex flex-wrap items-center gap-3 border-b border-edge px-4 py-3 last:border-b-0"
    >
      <div class="min-w-0 flex-1">
        <p class="text-sm font-medium text-ink">{@name}</p>
        <p class="mt-0.5 text-xs text-muted">{@detail}</p>
      </div>
      <span class={permission_pill_class(@granted)}>
        {if @granted, do: "granted", else: "not granted"}
      </span>
      <button
        :if={!@granted}
        id={@id <> "-open-settings"}
        type="button"
        phx-click="open_system_settings"
        phx-value-pane={@pane}
        class={pill_button_class()}
      >
        Open System Settings
      </button>
    </div>
    """
  end

  attr :backend, :map, required: true

  defp preview_card(assigns) do
    ~H"""
    <section id="computer-preview">
      <.section_title>Screens & windows</.section_title>
      <div class={card_class()}>
        <%= case @backend.screens do %>
          <% {:ok, screens} -> %>
            <div class="grid gap-1 px-4 py-2.5 text-xs">
              <p
                :for={screen <- screens}
                data-screen-id={screen.id}
                class="font-mono text-ink"
              >
                display {screen.index + 1}{if screen.main, do: " (main)", else: ""} — {trunc(
                  screen.bounds.width
                )}×{trunc(screen.bounds.height)} pt @ {screen.scale}x
              </p>
            </div>
          <% {:error, _reason} -> %>
            <p class="px-4 py-2.5 text-xs text-muted">
              Displays: unavailable.
            </p>
          <% :pending -> %>
            <p class="px-4 py-2.5 text-xs text-muted">
              Displays: loading…
            </p>
          <% _unavailable -> %>
            <p class="px-4 py-2.5 text-xs text-muted">
              Displays: reported once the backend is available.
            </p>
        <% end %>
        <%= case @backend.windows do %>
          <% {:ok, windows} -> %>
            <div class="border-t border-edge px-4 py-2.5 text-xs">
              <p class="text-muted">
                {length(windows)} on-screen windows
              </p>
              <p
                :for={window <- Enum.take(windows, 8)}
                class="mt-1 truncate font-mono text-ink"
              >
                #{window.id} {window.app} — {window.title}
              </p>
            </div>
          <% :pending -> %>
            <p class="border-t border-edge px-4 py-2.5 text-xs text-muted">
              Windows: loading…
            </p>
          <% _error_or_unavailable -> %>
            <p class="border-t border-edge px-4 py-2.5 text-xs text-muted">
              Windows: unavailable (Screen Recording is needed to read window titles).
            </p>
        <% end %>
      </div>
    </section>
    """
  end

  defp posture_card(assigns) do
    ~H"""
    <section id="computer-posture">
      <.section_title>What this allows</.section_title>
      <div class="rounded-xl border border-amber-300/60 bg-amber-50/90 px-4 py-3 text-xs leading-5 text-amber-900 dark:border-amber-400/30 dark:bg-amber-500/10 dark:text-amber-200">
        <p class="font-semibold">There is no sandbox.</p>
        <p class="mt-1">
          With computer use armed the agent can do anything you can do on this machine. Screen
          contents and fetched pages are untrusted input — a page or window can try to instruct the
          agent. The counterweights are this off-by-default toggle, non-inheritance into subagents,
          and your own <code class="font-mono">before_tool_call</code> permission hooks.
        </p>
      </div>
    </section>
    """
  end

  # ---- labels and classes ------------------------------------------------------

  defp grant_label(true, true), do: "on"
  defp grant_label(true, false), do: "on — but no backend"
  defp grant_label(false, _available?), do: "off"

  defp toggle_label(true), do: "Turn off"
  defp toggle_label(false), do: "Turn on"

  defp backend_status_key(:ok), do: "ok"
  defp backend_status_key({:error, reason}), do: Atom.to_string(reason)

  defp helper_liveness_label(:open), do: "running (Port open)"
  defp helper_liveness_label(:closed), do: "not running — starts lazily on first use"

  defp permission_pill_class(true) do
    "rounded-full border border-ok/40 bg-ok/10 px-2.5 py-1 text-xs font-semibold text-ok"
  end

  defp permission_pill_class(false) do
    "rounded-full border border-amber-500/50 bg-amber-500/10 px-2.5 py-1 text-xs " <>
      "font-semibold text-amber-700 dark:border-amber-400/40 dark:bg-amber-400/10 " <>
      "dark:text-amber-300"
  end

  defp state_pill_class(true) do
    "rounded-full border border-danger/40 bg-danger/10 px-2.5 py-1 text-xs font-semibold text-danger"
  end

  defp state_pill_class(false) do
    "rounded-full border border-edge px-2.5 py-1 text-xs font-semibold text-muted"
  end

  defp section_title(assigns) do
    ~H"""
    <h2 class="mb-2 text-xs font-semibold uppercase tracking-wide text-faint">
      {render_slot(@inner_block)}
    </h2>
    """
  end

  defp card_class do
    "overflow-hidden rounded-xl border border-edge bg-surface"
  end

  defp pill_button_class do
    "rounded-full border border-edge px-3 py-1 text-xs font-medium text-muted transition " <>
      "hover:bg-raised hover:text-ink"
  end
end
