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
end
