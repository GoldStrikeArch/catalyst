defmodule CatalystWeb.ChatLiveTest do
  use CatalystWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the chat shell with the Codex run controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#codex-opts")
    refute has_element?(view, "#catalyst-shell", "Demo (offline)")
    assert has_element?(view, "#chat-empty-state")
    assert has_element?(view, "#chat-form")
    assert has_element?(view, "#composer-shell #chat-input")
    assert has_element?(view, "#run-send")
    refute has_element?(view, "#run-stop")
  end

  test "sending a prompt streams a reply with a tool result (offline provider)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    submit_prompt(view, "list the files")

    assert has_element?(view, "#message-stream", "list the files")
    assert has_element?(view, "#message-stream", "offline Demo provider")
    assert has_element?(view, "#message-stream code", "ls")
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
    submit_prompt(view, "list the files")
    assert has_element?(view, "#message-stream", "list the files")

    # A reconnect/refresh mounts a fresh LiveView; it must pick up the same
    # session and replay the conversation instead of starting over.
    {:ok, view2, _html} = live(conn, ~p"/")
    assert session_id(view2) == id

    assert has_element?(view2, "#message-stream", "list the files")
    assert has_element?(view2, "#message-stream", "offline Demo provider")
    refute has_element?(view2, "#chat-empty-state")
  end

  test "the Sign in button runs OAuth (stubbed) without restarting the session", %{conn: conn} do
    parent = self()

    Application.put_env(:catalyst_web, :login_fun, fn ->
      send(parent, :login_called)
      {:ok, "acct_test"}
    end)

    on_exit(fn -> Application.delete_env(:catalyst_web, :login_fun) end)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#login-button", "Sign in to ChatGPT")
    id = session_id(view)
    submit_prompt(view, "hello there")
    assert has_element?(view, "#message-stream", "hello there")

    view |> element("#login-button") |> render_click()
    assert_receive :login_called, 1_000

    refute has_element?(view, "#login-button")
    assert has_element?(view, ~s(#logout-button[title="Sign out of ChatGPT"]))

    # The token is fetched per turn — signing in must NOT restart the session
    # or wipe the conversation.
    assert session_id(view) == id
    assert has_element?(view, "#message-stream", "hello there")
  end
end
