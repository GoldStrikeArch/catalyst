defmodule CatalystWeb.ShellLiveTest do
  # async: false — registers into the global CatalystWeb.UI.Registry.
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Agent.Event
  alias Catalyst.LLM.Event, as: LLMEvent
  alias Catalyst.{Content, Message}
  alias Catalyst.Session.Server
  alias CatalystWeb.UI.Registry

  defmodule SettingsPage do
    use CatalystWeb, :html
    def render(assigns), do: ~H|<div>SETTINGS-PAGE-CONTENT</div>|
  end

  defmodule BrokenPage do
    use CatalystWeb, :html
    # Building this template succeeds; @missing_assign is only fetched (and
    # raises) when the Rendered's dynamics are evaluated — i.e. at diff time,
    # which is exactly what render_active_page's forced evaluation must trap.
    def render(assigns), do: ~H|<div>BROKEN-PAGE:{@missing_assign}</div>|
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
    id = session_id(view)
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    view
    |> form("#chat-form", %{"message" => prompt})
    |> render_submit()

    # Broadcasts are tagged with the broadcasting session's id.
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 5_000
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

  test "an extension page that raises at diff time falls back to chat", %{conn: conn} do
    on_exit(fn -> Registry.unregister_owner("e5_broken_page") end)

    Registry.register_page("broken", {BrokenPage, :render},
      owner: "e5_broken_page",
      label: "Broken"
    )

    # The template raises only when its dynamics run (missing assign), so a
    # guard around the lazy build alone would let the diff engine crash-loop
    # the LiveView. Forced evaluation renders the chat fallback instead.
    {:ok, view, html} = live(conn, "/broken")
    refute html =~ "BROKEN-PAGE"
    assert html =~ "Ask Catalyst to inspect this project."
    assert has_element?(view, "#chat-form")
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

  test "streaming shows a loader and hides partial deltas until the final assistant message",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    id = session_id(view)

    send(
      view.pid,
      {:agent_event, id, %Event.MessageStart{message: %Message.Assistant{content: []}}}
    )

    assert has_element?(view, "#streaming-message")
    assert render(view) =~ "Assistant is working"

    send(
      view.pid,
      {:agent_event, id,
       %Event.MessageUpdate{llm_event: %LLMEvent.TextDelta{delta: "- partial `item`"}}}
    )

    html = render(view)
    assert html =~ "Assistant is working"
    refute html =~ "partial"

    final = %Message.Assistant{content: Content.text("- final `item`")}
    send(view.pid, {:agent_event, id, %Event.MessageEnd{message: final}})

    refute has_element?(view, "#streaming-message")
    assert has_element?(view, "ul li")
    assert has_element?(view, "code", "item")
    assert render(view) =~ "final"
  end

  test "tool execution indicators and results render immediately", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    id = session_id(view)

    send(
      view.pid,
      {:agent_event, id, %Event.ToolExecutionStart{call_id: "call-1", name: "grep", args: %{}}}
    )

    assert render(view) =~ "running"
    assert has_element?(view, "code", "grep")

    result = %Message.ToolResult{
      tool_call_id: "call-1",
      tool_name: "grep",
      content: Content.text("found it")
    }

    send(view.pid, {:agent_event, id, %Event.MessageEnd{message: result}})

    assert has_element?(view, ~s([data-message-role="tool-result"]))
    assert render(view) =~ "found it"

    send(view.pid, {:agent_event, id, %Event.ToolExecutionEnd{call_id: "call-1"}})

    refute render(view) =~ "running"
  end

  test "an event tagged with another session's id is dropped, not rendered", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    leaked = %Message.Assistant{content: Content.text("LEAKED-FROM-OTHER-SESSION")}

    send(
      view.pid,
      {:agent_event, "not-" <> session_id(view), %Event.MessageEnd{message: leaked}}
    )

    refute render(view) =~ "LEAKED-FROM-OTHER-SESSION"
    # The transcript is untouched — the empty state is still up.
    assert has_element?(view, "#chat-empty-state")
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

  test "/cd relative paths resolve from the active session cwd", %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "catalyst_cd_#{System.unique_integer([:positive])}")
    parent = Path.join(root, "parent")
    child = Path.join(parent, "child")

    File.mkdir_p!(child)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("#chat-form", %{"message" => "/cd #{parent}"}) |> render_submit()
    assert render(view) =~ parent

    view |> form("#chat-form", %{"message" => "/cd child"}) |> render_submit()

    html = render(view)
    assert html =~ child
    refute html =~ "Not a directory"
  end
end
