defmodule CatalystWeb.ShellLiveTest do
  # async: false — registers into the global CatalystWeb.UI.Registry.
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Message
  alias CatalystWeb.UI.Registry

  defmodule SettingsPage do
    use CatalystWeb, :html
    def render(assigns), do: ~H|<div>SETTINGS-PAGE-CONTENT</div>|
  end

  defmodule LsRenderer do
    use CatalystWeb, :html
    def card(assigns), do: ~H|<div>CUSTOM-LS-CARD:{@msg.tool_name}</div>|
  end

  defp wait_render(_view, sub, 0), do: flunk("did not render #{inspect(sub)} in time")

  defp wait_render(view, sub, tries) do
    html = render(view)

    if html =~ sub,
      do: html,
      else:
        (
          Process.sleep(50)
          wait_render(view, sub, tries - 1)
        )
  end

  test "a runtime-registered page renders via the catch-all route", %{conn: conn} do
    on_exit(fn -> Registry.unregister_owner("e5_page") end)

    Registry.register_page("settings", {SettingsPage, :render},
      owner: "e5_page",
      label: "Settings"
    )

    {:ok, _view, html} = live(conn, "/settings")
    assert html =~ "SETTINGS-PAGE-CONTENT"
    # The page nav now lists both pages.
    assert html =~ "Settings"
  end

  test "a custom message renderer overrides the built-in tool card", %{conn: conn} do
    on_exit(fn -> Registry.unregister_owner("e5_render") end)

    Registry.register_renderer(
      :message,
      fn msg -> match?(%Message.ToolResult{tool_name: "ls"}, msg) end,
      &LsRenderer.card/1,
      owner: "e5_render"
    )

    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("form", %{"message" => "list the files"}) |> render_submit()

    # The Demo provider runs `ls`; our custom renderer replaces the default card.
    assert wait_render(view, "CUSTOM-LS-CARD", 80) =~ "CUSTOM-LS-CARD:ls"
  end

  test "the chat page is the default at /", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Catalyst"
    assert html =~ "Ask Catalyst"
  end

  test "the web self-modification tools are registered into the core tool set" do
    assert Catalyst.Extensions.fetch("rebuild_assets") == CatalystWeb.Tools.RebuildAssets
    assert Catalyst.Extensions.fetch("reload_ui") == CatalystWeb.Tools.ReconnectUi
  end

  test "an asset reload broadcast triggers a full page reload in connected views", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    CatalystWeb.Assets.reload()
    assert_redirect(view, "/")
  end
end
