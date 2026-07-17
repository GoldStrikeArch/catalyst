defmodule CatalystWeb.ExtensionsPageTest do
  # async: false — drives the global Extensions registry and the shared
  # extensions dir (same reasoning as ShellLiveTest / ExtensionsTest).
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Agent.Event
  alias Catalyst.Extensions
  alias Catalyst.Session.Server

  @probe_source ~S'''
  defmodule Catalyst.Ext.PanelProbeTool do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "panel_probe"
    @impl true
    def description, do: "extensions panel test tool"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx), do: result("ok")
  end
  '''

  defp install_probe! do
    File.mkdir_p!(Extensions.dir())
    path = Path.join(Extensions.dir(), "panel_probe.ex")
    File.write!(path, @probe_source)
    {:ok, _summary} = Extensions.load_file(path)

    on_exit(fn ->
      Extensions.uninstall("panel_probe")
      File.rm(path)
      File.rm(path <> ".disabled")
    end)

    path
  end

  # Panel actions run in a supervised task; poll the condition (and the view,
  # so the handle_info result gets rendered) instead of racing it.
  defp wait_until(fun, tries \\ 150) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  test "the panel lists loaded extensions and the live registry contents", %{conn: conn} do
    install_probe!()

    {:ok, _view, html} = live(conn, "/extensions")

    # The loaded extension card, with its tool chip and action buttons.
    assert html =~ ~s(data-ext-owner="panel_probe")
    assert html =~ "panel_probe"
    assert html =~ "Disable"

    # Registry introspection: built-in tools, providers, and pages all listed.
    assert html =~ "Live registries"
    assert html =~ "built-in"
    assert html =~ "develop_tool"
    assert html =~ "faux"
    assert html =~ "/extensions"

    # The commands registry has producers: the built-in /cd is seeded there.
    assert html =~ "change the session working directory"

    # The nav now has two built-in pages.
    assert html =~ "Chat"
    assert html =~ "Extensions"
  end

  test "safe mode shows the shell banner and 'Load extensions now' recovers", %{conn: conn} do
    :persistent_term.put({Catalyst.Extensions, :boot_status}, {:safe_mode, :crash_detected})
    on_exit(fn -> :persistent_term.put({Catalyst.Extensions, :boot_status}, :ok) end)

    # The banner shows on every page and links to the panel.
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Extensions were not loaded"
    assert html =~ "previous boot crashed while extensions were active"

    {:ok, view, html} = live(conn, "/extensions")
    assert html =~ "Load extensions now"

    # Recovery: an explicit successful load clears safe mode (empty dir → ok).
    view |> element("button", "Load extensions now") |> render_click()
    assert wait_until(fn -> Catalyst.Extensions.boot_status() == :ok end)
    assert wait_until(fn -> not (render(view) =~ "Load extensions now") end)

    refute render(view) =~ "Extensions were not loaded"
  end

  test "disable and enable round-trip through the panel buttons", %{conn: conn} do
    path = install_probe!()

    {:ok, view, _html} = live(conn, "/extensions")

    view
    |> element(~s([data-ext-owner="panel_probe"] button), "Disable")
    |> render_click()

    assert wait_until(fn -> Extensions.fetch("panel_probe") == :error end)
    assert wait_until(fn -> render(view) =~ "Enable" end)
    assert File.exists?(path <> ".disabled")

    view
    |> element(~s([data-ext-owner="panel_probe"] button), "Enable")
    |> render_click()

    assert wait_until(fn -> match?({:ok, _}, Extensions.fetch("panel_probe")) end)
    assert wait_until(fn -> render(view) =~ "Enabled panel_probe" end)
    assert File.exists?(path)
  end

  test "reload all reports its result in a flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/extensions")

    view |> element("button", "Reload all") |> render_click()

    assert wait_until(fn -> render(view) =~ "Reloaded" end)
  end

  test "patching to the panel and back preserves the chat transcript", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    html = submit_prompt(view, "panel roundtrip probe")
    assert html =~ "panel roundtrip probe"

    render_patch(view, "/extensions")
    html = render_patch(view, "/")

    # Stream items live only in the DOM the panel replaced — without the
    # replay in change_page/2 the transcript would come back empty.
    assert html =~ "panel roundtrip probe"
  end

  defp session_id(view) do
    html = view |> element("#catalyst-shell") |> render()
    [_, id] = Regex.run(~r/data-session-id="([^"]+)"/, html)
    id
  end

  defp submit_prompt(view, prompt) do
    id = session_id(view)
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    view
    |> form("#chat-form", %{"message" => prompt})
    |> render_submit()

    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 5_000
    render(view)
  end
end
