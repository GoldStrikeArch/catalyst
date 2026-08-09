defmodule CatalystWeb.ComputerUseTest do
  # async: false — writes the shared machine_prefs persistent_term and the
  # :catalyst backend-availability app env.
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Session.{Manager, Server}
  alias CatalystWeb.Pages.ComputerPage
  alias CatalystWeb.ShellLive.Settings

  @machine_prefs_ptr {CatalystWeb.ShellLive, :machine_prefs}
  @codex_prefs_ptr {CatalystWeb.ShellLive, :codex_prefs}

  defmodule PageStubBackend do
    @moduledoc false
    @behaviour Catalyst.Tools.Computer.Backend

    @recorder_key {__MODULE__, :recorder}

    def record_to(pid), do: :persistent_term.put(@recorder_key, pid)
    def stop_recording, do: :persistent_term.erase(@recorder_key)

    defp record(call) do
      case :persistent_term.get(@recorder_key, nil) do
        pid when is_pid(pid) -> send(pid, {:page_stub, call})
        nil -> :ok
      end
    end

    @impl true
    def screens do
      record(:screens)

      {:ok,
       [
         %{
           id: 1,
           index: 0,
           main: true,
           bounds: %{x: 0, y: 0, width: 1440, height: 900},
           scale: 2.0
         }
       ]}
    end

    @impl true
    def windows do
      record(:windows)

      {:ok,
       [
         %{
           id: 42,
           pid: 7,
           app: "TestApp",
           title: "Doc",
           layer: 0,
           bounds: %{x: 0, y: 0, width: 100, height: 100}
         }
       ]}
    end

    @impl true
    def cursor, do: {:ok, %{x: 0, y: 0}}

    @impl true
    def input(_op), do: {:ok, %{}}

    @impl true
    def capture(_request), do: {:error, :not_implemented}

    @impl true
    def grants do
      record(:grants)
      {:ok, %{accessibility: true, screen_recording: false}}
    end

    @impl true
    def capture_grant do
      record(:capture_grant)
      {:ok, false}
    end
  end

  setup do
    previous_backend = Application.fetch_env(:catalyst, :computer_backend_available)
    previous_module = Application.fetch_env(:catalyst, :computer_backend)

    # `sync_from_session/1` persists BOTH prefs terms, so a test that drives it
    # directly would otherwise leak a Codex setting into every later test in the
    # suite (these terms are global, and this module is async: false).
    marker = make_ref()
    previous_codex = :persistent_term.get(@codex_prefs_ptr, marker)

    on_exit(fn ->
      :persistent_term.erase(@machine_prefs_ptr)

      case previous_codex do
        ^marker -> :persistent_term.erase(@codex_prefs_ptr)
        prefs -> :persistent_term.put(@codex_prefs_ptr, prefs)
      end

      PageStubBackend.stop_recording()

      restore = fn key, previous ->
        case previous do
          {:ok, value} -> Application.put_env(:catalyst, key, value)
          :error -> Application.delete_env(:catalyst, key)
        end
      end

      restore.(:computer_backend_available, previous_backend)
      restore.(:computer_backend, previous_module)
    end)

    :ok
  end

  defp session_pid(view) do
    {:ok, pid} = Manager.whereis(session_id(view))
    pid
  end

  test "the header toggle flips the session's computer-use option", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    pid = session_pid(view)

    assert Server.state(pid).opts[:computer_use] == false

    view |> element("#computer-toggle") |> render_click()
    assert Server.state(pid).opts[:computer_use] == true

    # Same session, same model — the grant applies to the next run and the
    # transcript is untouched.
    assert session_pid(view) == pid

    view |> element("#computer-toggle") |> render_click()
    assert Server.state(pid).opts[:computer_use] == false
  end

  test "the grant persists across a remount and into a new session", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("#computer-toggle") |> render_click()

    {:ok, view2, _html} = live(conn, "/")
    assert has_element?(view2, ~s(#computer-toggle[aria-pressed="true"]))

    view2 |> element("#new-session-button") |> render_click()
    assert Server.state(session_pid(view2)).opts[:computer_use] == true
  end

  test "the toggle never leaves the Codex controls behind", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    pid = session_pid(view)

    before_opts = Server.state(pid).opts
    view |> element("#computer-toggle") |> render_click()
    after_opts = Server.state(pid).opts

    assert after_opts[:reasoning_effort] == before_opts[:reasoning_effort]
    assert after_opts[:transport] == before_opts[:transport]
  end

  test "/computer renders the no-backend state", %{conn: conn} do
    Application.put_env(:catalyst, :computer_backend_available, false)
    {:ok, view, _html} = live(conn, "/computer")

    assert has_element?(view, "#computer-page")
    assert has_element?(view, "#computer-helper-path")
    assert has_element?(view, ~s(#computer-grant-state[data-granted="false"]))
    refute has_element?(view, ~s([data-backend-status="ok"]))

    assert has_element?(
             view,
             ~s([data-backend-status="helper_missing"], [data-backend-status="unsupported_platform"])
           )
  end

  test "/computer reports an armed toggle that the backend cannot honor", %{conn: conn} do
    Application.put_env(:catalyst, :computer_backend_available, false)
    {:ok, view, _html} = live(conn, "/computer")

    view |> element("#computer-page-toggle") |> render_click()

    # The toggle is on, the grant is not: the page must not claim otherwise.
    assert has_element?(view, ~s(#computer-grant-state[data-toggle="true"]))
    assert has_element?(view, ~s(#computer-grant-state[data-granted="false"]))
  end

  test "/computer reports the granted state when a backend is available", %{conn: conn} do
    Application.put_env(:catalyst, :computer_backend_available, true)
    {:ok, view, _html} = live(conn, "/computer")

    assert has_element?(view, ~s([data-backend-status="ok"]))
    assert has_element?(view, ~s(#computer-grant-state[data-granted="false"]))

    view |> element("#computer-page-toggle") |> render_click()
    assert has_element?(view, ~s(#computer-grant-state[data-granted="true"]))
  end

  test "backend_state/0 is the seam later phases extend" do
    Application.put_env(:catalyst, :computer_backend_available, true)
    assert %{available?: true, status: :ok, helper_path: path} = ComputerPage.backend_state()
    assert is_binary(path)

    Application.put_env(:catalyst, :computer_backend_available, false)
    assert %{available?: false, status: {:error, _reason}} = ComputerPage.backend_state()
  end

  test "/computer reports grants, liveness, and previews with a present backend", %{conn: conn} do
    # Clear the test-env availability pin so detection runs: an explicitly
    # configured backend module counts as available without a helper binary.
    Application.delete_env(:catalyst, :computer_backend_available)
    Application.put_env(:catalyst, :computer_backend, PageStubBackend)
    {:ok, view, _html} = live(conn, "/computer")

    # The snapshot is fetched off the LiveView callback; await it before
    # asserting on the queried rows.
    render_async(view)

    assert has_element?(view, ~s([data-backend-status="ok"]))

    # TCC grant state via the stub backend's grants/0 (read-only preflight ops).
    assert has_element?(view, ~s(#computer-grant-accessibility[data-granted="true"]))
    assert has_element?(view, ~s(#computer-grant-screen-recording[data-granted="false"]))

    # The ungranted permission opens System Settings server-side via open(1) —
    # the desktop wxWebView cannot navigate x-apple.systempreferences: links,
    # so the button sends a pane key rather than being a plain href.
    test_pid = self()
    previous_open = Application.fetch_env(:catalyst_web, :open_url_fun)

    Application.put_env(:catalyst_web, :open_url_fun, fn url ->
      send(test_pid, {:opened, url})
    end)

    on_exit(fn ->
      case previous_open do
        {:ok, value} -> Application.put_env(:catalyst_web, :open_url_fun, value)
        :error -> Application.delete_env(:catalyst_web, :open_url_fun)
      end
    end)

    view
    |> element("#computer-grant-screen-recording-open-settings")
    |> render_click()

    assert_receive {:opened, "x-apple.systempreferences:" <> pane_url}
    assert pane_url =~ "Privacy_ScreenCapture"

    # The granted permission offers no settings button at all.
    refute has_element?(view, "#computer-grant-accessibility-open-settings")

    # Helper liveness (never started by rendering with a stub backend).
    assert has_element?(view, ~s(#computer-helper-liveness[data-helper-port="closed"]))

    # Screens/windows preview.
    assert has_element?(view, "#computer-preview")
    assert render(element(view, "#computer-preview")) =~ "TestApp"
  end

  test "/computer never queries grants when the backend is unavailable", %{conn: conn} do
    Application.put_env(:catalyst, :computer_backend_available, false)
    {:ok, view, _html} = live(conn, "/computer")

    refute has_element?(view, "#computer-permissions")
    refute has_element?(view, "#computer-preview")
  end

  test "the computer page is registered like every other built-in page" do
    assert {:ok, {ComputerPage, :render}} = CatalystWeb.UI.Registry.fetch_page("computer")
    assert Enum.any?(CatalystWeb.UI.Registry.list_pages(), &(&1.path == "computer"))
  end

  defp drain_stub_calls do
    receive do
      {:page_stub, _call} -> drain_stub_calls()
    after
      0 -> :ok
    end
  end

  test "/computer renders from the cached snapshot — no backend query on unrelated re-renders",
       %{conn: conn} do
    Application.delete_env(:catalyst, :computer_backend_available)
    Application.put_env(:catalyst, :computer_backend, PageStubBackend)
    PageStubBackend.record_to(self())

    # Navigation computes the snapshot (once per handle_params pass) — in an
    # async task, so await its completion before draining the recorded calls.
    {:ok, view, _html} = live(conn, "/computer")
    assert_receive {:page_stub, :grants}
    render_async(view)
    drain_stub_calls()

    # An unrelated assign change re-renders the page from cached assigns:
    # streaming output must never stall on synchronous helper round-trips.
    view |> element("#quiet-toggle") |> render_click()
    _rerendered = render(view)
    refute_receive {:page_stub, _call}, 100

    # The page still shows the cached backend data.
    assert has_element?(view, ~s([data-backend-status="ok"]))
    assert render(element(view, "#computer-preview")) =~ "TestApp"

    # The explicit Refresh button re-queries on demand.
    view |> element("#computer-refresh") |> render_click()
    assert_receive {:page_stub, :grants}
  end

  defmodule SlowStubBackend do
    @moduledoc false
    # Every op takes 600ms, as a wedged (but alive) helper would.
    @behaviour Catalyst.Tools.Computer.Backend

    defp slow(value) do
      Process.sleep(600)
      value
    end

    @impl true
    def screens, do: slow({:ok, []})

    @impl true
    def windows, do: slow({:ok, []})

    @impl true
    def cursor, do: slow({:ok, %{x: 0, y: 0}})

    @impl true
    def input(_op), do: slow({:ok, %{"ok" => true}})

    @impl true
    def capture(_request), do: slow({:error, :unsupported_platform})

    @impl true
    def grants, do: slow({:ok, %{accessibility: true, screen_recording: true}})

    @impl true
    def capture_grant, do: slow({:ok, true})
  end

  defmodule DisagreeingStubBackend do
    @moduledoc false
    # The helper holds the grant; the process that actually runs `screencapture`
    # does not. This is the ordinary dev situation: two TCC subjects, one .app.
    @behaviour Catalyst.Tools.Computer.Backend

    @impl true
    def screens do
      {:ok,
       [
         %{
           id: 1,
           index: 0,
           main: true,
           bounds: %{x: 0, y: 0, width: 1440, height: 900},
           scale: 2.0
         }
       ]}
    end

    @impl true
    def windows, do: {:ok, []}

    @impl true
    def cursor, do: {:ok, %{x: 0, y: 0}}

    @impl true
    def input(_op), do: {:ok, %{"ok" => true}}

    @impl true
    def capture(_request), do: {:error, {:capture_failed, "not authorized to capture"}}

    @impl true
    def grants, do: {:ok, %{accessibility: true, screen_recording: true}}

    # The capture-path probe answers for the BEAM-spawned screencapture, which
    # holds no grant here — the readiness the page must report.
    @impl true
    def capture_grant, do: {:ok, false}
  end

  describe "audit regressions" do
    # AUDIT: `Settings.sync_from_session/1` reconciles only `codex_prefs` from
    # the attached session's authoritative opts; `machine_prefs` is a global
    # persistent_term that is never reconciled. A session configured directly
    # (`Server.configure(pid, opts: [computer_use: true])`), or a second view of
    # a different session, therefore renders the safety toggle in a state the
    # session does not have.
    @tag :audit
    test "syncing from a session reconciles the computer-use toggle" do
      # The attached session is armed; the (global, per-browser) preference is
      # not. sync_from_session/1 is the reconciliation point and must cover the
      # capability, exactly as it covers effort/transport/fast.
      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(%{
          session_model: nil,
          session_opts: [computer_use: true, reasoning_effort: "high"],
          codex_prefs: Settings.load_codex(),
          machine_prefs: %{computer_use: false}
        })

      synced = Settings.sync_from_session(socket)

      assert synced.assigns.codex_prefs.effort == "high"

      assert synced.assigns.machine_prefs.computer_use == true,
             "the toggle stayed off for a session that has computer use on"
    end

    # AUDIT: `backend_state/0` performs up to four synchronous helper round-trips
    # (grants is two ops, plus screens and windows), each with a 10s
    # `GenServer.call` budget, and `maybe_refresh_panel/1` runs it inline from
    # mount, navigation, toggling, refresh, and `AgentEnd`. A wedged helper
    # freezes the LiveView for tens of seconds. The snapshot must be computed
    # off the callback (async assign / task), not inside it.
    @tag :audit
    @tag timeout: 60_000
    test "a slow backend does not block the LiveView callback", %{conn: conn} do
      Application.delete_env(:catalyst, :computer_backend_available)
      Application.put_env(:catalyst, :computer_backend, SlowStubBackend)

      {elapsed_us, {:ok, view, _html}} = :timer.tc(fn -> live(conn, "/computer") end)

      assert div(elapsed_us, 1000) < 1_000,
             "mounting /computer blocked for #{div(elapsed_us, 1000)}ms on backend round-trips"

      assert has_element?(view, "#computer-permissions")
    end

    # AUDIT: the Screen Recording row is fed by `grants/0`, which asks the
    # *helper* process (CGPreflightScreenCaptureAccess checks its own caller).
    # Screenshots are taken by /usr/sbin/screencapture spawned from the BEAM — a
    # different TCC subject. The page therefore presents one process's grant as
    # another's readiness, which is precisely the failure /computer exists to
    # prevent ("the agent silently screenshotting a blank desktop").
    @tag :audit
    test "screenshot readiness comes from the capture path, not the helper", %{conn: conn} do
      Application.delete_env(:catalyst, :computer_backend_available)
      Application.put_env(:catalyst, :computer_backend, DisagreeingStubBackend)

      {:ok, view, _html} = live(conn, "/computer")

      # Await the async snapshot so the refutation runs against the resolved
      # permission rows, not the loading state.
      render_async(view)

      assert has_element?(view, ~s(#computer-grant-accessibility[data-granted="true"]))

      refute has_element?(view, ~s(#computer-grant-screen-recording[data-granted="true"])),
             "Screen Recording shows as granted although the capture path is denied"
    end
  end
end
