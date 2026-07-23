defmodule CatalystWeb.QuietModeTest do
  # async: false — writes the shared ui_prefs persistent_term.
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message}
  alias Catalyst.Session.{Manager, Server}

  setup do
    on_exit(fn -> :persistent_term.erase({CatalystWeb.ShellLive, :ui_prefs}) end)
    :ok
  end

  defp session_pid(view) do
    {:ok, pid} = Manager.whereis(session_id(view))
    pid
  end

  test "the header toggle flips the transcript's data-quiet attribute", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "#messages[data-quiet]")

    view |> element("#quiet-toggle") |> render_click()
    assert has_element?(view, "#messages[data-quiet]")

    view |> element("#quiet-toggle") |> render_click()
    refute has_element?(view, "#messages[data-quiet]")
  end

  test "quiet persists across a remount like other header prefs", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element("#quiet-toggle") |> render_click()

    {:ok, view2, _html} = live(conn, "/")
    assert has_element?(view2, "#messages[data-quiet]")
  end

  # Quiet hides via CSS ([data-quiet] rules in app.css), so LiveViewTest cannot
  # assert visual hiding — no styles are computed here. What it CAN assert: the
  # attribute is set, the noisy markup still EXISTS in the DOM (the toggle is
  # retroactive and lossless), and the session was never touched.
  test "quiet is display-only: tool markup stays in the DOM, session untouched",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    pid = session_pid(view)

    # Demo-provider run: a tool-call chip, then a tool-result card.
    submit_prompt(view, "list the files")
    assert has_element?(view, ~s(#messages [data-block-kind="tool-call"]))
    assert has_element?(view, ~s(#messages [data-message-role="tool-result"]))

    snap_before = Server.state(pid)
    view |> element("#quiet-toggle") |> render_click()

    assert has_element?(view, "#messages[data-quiet]")
    assert has_element?(view, ~s(#messages [data-block-kind="tool-call"]))
    assert has_element?(view, ~s(#messages [data-message-role="tool-result"]))

    # UI-only: same session process, same model/opts — no Server.configure ran.
    snap_after = Server.state(pid)
    assert session_pid(view) == pid
    assert snap_after.model == snap_before.model
    assert snap_after.opts == snap_before.opts
  end

  test "a thinking message keeps its markup while quiet", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    id = session_id(view)

    view |> element("#quiet-toggle") |> render_click()

    msg = %Message.Assistant{
      content: [
        %Content.Thinking{thinking: "pondering"},
        %Content.ToolCall{id: "c1", name: "ls", arguments: %{}}
      ]
    }

    send(
      view.pid,
      {:agent_event, id, %Event.MessageStart{message: %Message.Assistant{content: []}}}
    )

    send(view.pid, {:agent_event, id, %Event.MessageEnd{message: msg}})

    assert has_element?(view, ~s(#messages [data-block-kind="thinking"]))
    assert has_element?(view, ~s(#messages [data-block-kind="tool-call"]))
    assert has_element?(view, "#messages[data-quiet]")
  end

  # The hiding itself lives in app.css and can't be exercised by LiveViewTest —
  # guard the selectors' existence at the source level so a CSS refactor can't
  # silently orphan the data-quiet attribute.
  test "app.css carries the quiet-mode rules the attribute relies on" do
    css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))

    assert css =~ ~s([data-quiet] [data-block-kind="tool-call"])
    assert css =~ ~s([data-quiet] [data-message-role="tool-result"])
    assert css =~ ~s([data-quiet] [data-block-kind="thinking"])
    assert css =~ ~s([data-quiet] [data-stream="thinking"])
  end
end
