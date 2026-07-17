defmodule CatalystWeb.ShellLiveTest do
  # async: false — registers into the global CatalystWeb.UI.Registry.
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Agent.Event
  alias Catalyst.Message
  alias Catalyst.Session.Server
  alias CatalystWeb.UI.Registry

  defmodule SettingsPage do
    use CatalystWeb, :html
    def render(assigns), do: ~H|<div>SETTINGS-PAGE-CONTENT</div>|
  end

  defmodule LsRenderer do
    use CatalystWeb, :html
    def card(assigns), do: ~H|<div>CUSTOM-LS-CARD:{@msg.tool_name}</div>|
  end

  defp session_id(view) do
    html = view |> element("#catalyst-shell") |> render()
    [_, id] = Regex.run(~r/data-session-id="([^"]+)"/, html)
    id
  end

  defp submit_prompt(view, prompt) do
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(session_id(view)))

    view
    |> form("#chat-form", %{"message" => prompt})
    |> render_submit()

    assert_receive {:agent_event, %Event.AgentEnd{}}, 5_000
    render(view)
  end

  test "a runtime-registered page renders via the catch-all route", %{conn: conn} do
    on_exit(fn -> Registry.unregister_owner("e5_page") end)

    Registry.register_page("settings", {SettingsPage, :render},
      owner: "e5_page",
      label: "Settings"
    )

    {:ok, _view, html} = live(conn, "/settings")
    assert html =~ "SETTINGS-PAGE-CONTENT"
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

    html = submit_prompt(view, "list the files")

    assert html =~ "CUSTOM-LS-CARD:ls"
    refute html =~ "Ask Catalyst to inspect this project."
  end

  test "the chat page is the default at /", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Catalyst"
    assert has_element?(view, "#chat-empty-state")
  end

  test "the chat starts empty and renders messages through a LiveView stream", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Ask Catalyst to inspect this project."
    assert has_element?(view, "#message-stream")
  end

  test "the web self-modification tools are registered into the core tool set" do
    assert Catalyst.Extensions.fetch("rebuild_assets") == {:ok, CatalystWeb.Tools.RebuildAssets}
    assert Catalyst.Extensions.fetch("reload_ui") == {:ok, CatalystWeb.Tools.ReconnectUi}
  end

  test "an asset reload broadcast triggers a full page reload in connected views", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    CatalystWeb.Assets.reload()
    assert_redirect(view, "/")
  end

  test "an asset reload keeps users on their current (non-chat) page", %{conn: conn} do
    on_exit(fn -> Registry.unregister_owner("e5_reload_page") end)

    Registry.register_page("settings", {SettingsPage, :render},
      owner: "e5_reload_page",
      label: "Settings"
    )

    {:ok, view, _html} = live(conn, "/settings")
    CatalystWeb.Assets.reload()
    assert_redirect(view, "/settings")
  end

  test "re-clicking the active provider keeps the session and transcript", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    id = session_id(view)
    assert submit_prompt(view, "list the files") =~ "list the files"

    view |> element("button", "Demo") |> render_click()

    # Same session, conversation intact — no restart for a no-op click.
    assert session_id(view) == id
    assert render(view) =~ "list the files"
  end

  test "a bare /cd flashes a usage hint instead of prompting the model", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("#chat-form", %{"message" => "/cd "}) |> render_submit()

    assert render(view) =~ "usage: /cd"
    # Nothing was sent to the agent.
    assert has_element?(view, "#chat-empty-state")
  end
end
