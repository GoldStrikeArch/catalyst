defmodule CatalystWeb.ChatLiveTest do
  use CatalystWeb.ConnCase

  import Phoenix.LiveViewTest

  defp wait_render(_view, sub, 0), do: flunk("did not render #{inspect(sub)} in time")

  defp wait_render(view, sub, tries) do
    html = render(view)
    if html =~ sub, do: html, else: (Process.sleep(50); wait_render(view, sub, tries - 1))
  end

  test "renders the chat shell with the Demo provider", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Catalyst"
    assert html =~ "Demo (offline)"
    assert html =~ "Ask Catalyst"
  end

  test "sending a prompt streams a Demo reply with a tool result", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("form", %{"message" => "list the files"})
    |> render_submit()

    # The user message is echoed back via the agent event stream.
    assert wait_render(view, "list the files", 80) =~ "list the files"

    # The Demo provider runs `ls` (a tool-result card) then streams a reply.
    html = wait_render(view, "offline Demo provider", 80)
    assert html =~ "ls"
  end

  test "the Sign in button runs OAuth (stubbed) and switches to Codex", %{conn: conn} do
    # Stub the OAuth flow so no browser/callback server is involved.
    Application.put_env(:catalyst_web, :login_fun, fn -> {:ok, "acct_test"} end)
    on_exit(fn -> Application.delete_env(:catalyst_web, :login_fun) end)

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Sign in to ChatGPT"

    view |> element("button", "Sign in to ChatGPT") |> render_click()

    # Async login result flips the UI to logged-in and switches the provider.
    html = wait_render(view, "Codex ✓", 80)
    refute html =~ "Sign in to ChatGPT"
    assert html =~ "Codex"
  end
end
