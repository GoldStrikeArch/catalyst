defmodule CatalystWeb.FileRefsLiveTest do
  # async: false — drives real sessions (and fd) through the shell.
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Agent.Event
  alias Catalyst.Session.Server

  # Mount the shell and point its session at a temp tree with two same-named
  # files (the disambiguation scenario from the design).
  defp mount_in_tmp_tree!(conn) do
    root = Path.join(System.tmp_dir!(), "catalyst_refs_#{System.unique_integer([:positive])}")

    for rel <- ["apps/x/session/server.ex", "qwe/server.ex"] do
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# #{rel}\n")
    end

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, view, _html} = live(conn, "/")
    view |> form("#chat-form", %{"message" => "/cd #{root}"}) |> render_submit()
    assert has_element?(view, "#chat-empty-state", root)
    view
  end

  test "typing @query shows disambiguated candidates; picking inserts the label",
       %{conn: conn} do
    view = mount_in_tmp_tree!(conn)

    view
    |> form("#chat-form", %{"message" => "look at @server"})
    |> render_change()

    # The fd search runs via start_async; wait for its result to render.
    render_async(view)

    assert has_element?(view, "#file-search-results")
    assert has_element?(view, "#file-search-results code", "@session/server.ex")
    assert has_element?(view, "#file-search-results code", "@qwe/server.ex")

    view
    |> element("#file-search-results button", "@session/server.ex")
    |> render_click()

    # The trailing @query is replaced by the short label in the input, and the
    # dropdown closes.
    assert has_element?(view, "#chat-form textarea", "look at @session/server.ex")
    refute has_element?(view, "#file-search-results")
  end

  test "sending expands picked labels into real cwd-relative paths", %{conn: conn} do
    view = mount_in_tmp_tree!(conn)

    view |> form("#chat-form", %{"message" => "read @server"}) |> render_change()
    render_async(view)
    view |> element("#file-search-results button", "@qwe/server.ex") |> render_click()

    id = session_id(view)
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    view
    |> form("#chat-form", %{"message" => "read @qwe/server.ex please"})
    |> render_submit()

    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 5_000

    # The transcript's user message carries the expanded path the model needs.
    assert has_element?(view, "#message-stream", "read qwe/server.ex please")
  end

  test "Enter with the dropdown open picks the first match instead of sending",
       %{conn: conn} do
    view = mount_in_tmp_tree!(conn)

    view |> form("#chat-form", %{"message" => "see @qwe"}) |> render_change()
    render_async(view)
    assert has_element?(view, "#file-search-results")

    view
    |> form("#chat-form", %{"message" => "see @qwe"})
    |> render_submit()

    # Picked, not sent: the label landed in the input and no run started.
    assert has_element?(view, "#chat-form textarea", "see @qwe/server.ex")
    assert has_element?(view, "#chat-empty-state")
  end
end
