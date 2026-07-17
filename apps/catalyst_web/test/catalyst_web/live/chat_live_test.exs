defmodule CatalystWeb.ChatLiveTest do
  use CatalystWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Catalyst.Agent.Event
  alias Catalyst.Session.Server

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

  test "renders the chat shell with the Demo provider", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Catalyst"
    assert html =~ "Demo (offline)"
    assert has_element?(view, "#chat-empty-state")
    assert has_element?(view, "#chat-form")
  end

  test "sending a prompt streams a Demo reply with a tool result", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = submit_prompt(view, "list the files")

    assert html =~ "list the files"
    assert html =~ "offline Demo provider"
    assert html =~ "ls"
    refute has_element?(view, "#chat-empty-state")
  end

  test "a remounted LiveView reattaches to the live session and its transcript", %{conn: conn} do
    # Earlier tests' sessions are still alive (sessions outlive their LiveView)
    # and have stored pointers — start this scenario from a clean slate.
    :persistent_term.erase({CatalystWeb.ShellLive, :current_session})
    Application.put_env(:catalyst_web, :reattach_sessions, true)

    on_exit(fn ->
      Application.put_env(:catalyst_web, :reattach_sessions, false)
      :persistent_term.erase({CatalystWeb.ShellLive, :current_session})
    end)

    {:ok, view, _html} = live(conn, ~p"/")
    id = session_id(view)
    assert submit_prompt(view, "list the files") =~ "list the files"

    # A reconnect/refresh mounts a fresh LiveView; it must pick up the same
    # session and replay the conversation instead of starting over.
    {:ok, view2, _html} = live(conn, ~p"/")
    assert session_id(view2) == id

    html = render(view2)
    assert html =~ "list the files"
    assert html =~ "offline Demo provider"
    refute has_element?(view2, "#chat-empty-state")
  end

  test "the Sign in button runs OAuth (stubbed) and switches to Codex", %{conn: conn} do
    parent = self()

    Application.put_env(:catalyst_web, :login_fun, fn ->
      send(parent, :login_called)
      {:ok, "acct_test"}
    end)

    on_exit(fn -> Application.delete_env(:catalyst_web, :login_fun) end)

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Sign in to ChatGPT"

    view |> element("button", "Sign in to ChatGPT") |> render_click()
    assert_receive :login_called, 1_000

    html = render(view)
    refute html =~ "Sign in to ChatGPT"
    assert html =~ "Codex"
  end
end
