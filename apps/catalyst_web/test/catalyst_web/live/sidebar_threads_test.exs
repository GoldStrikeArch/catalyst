defmodule CatalystWeb.SidebarThreadsTest do
  # async: false — writes the shared session catalog and ui_prefs.
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Session.{Catalog, Manager}
  alias CatalystWeb.ShellLive.Threads

  @ui_prefs_ptr {CatalystWeb.ShellLive, :ui_prefs}

  setup do
    previous_catalog = Application.get_env(:catalyst, :session_catalog_path)
    previous_ui = :persistent_term.get(@ui_prefs_ptr, :not_set)

    catalog =
      Path.join(
        System.tmp_dir!(),
        "catalyst_sidebar_#{System.unique_integer([:positive])}.json"
      )

    Application.put_env(:catalyst, :session_catalog_path, catalog)
    :persistent_term.erase(@ui_prefs_ptr)

    on_exit(fn ->
      restore_catalog(previous_catalog)
      restore_ui(previous_ui)
      File.rm(catalog)
    end)

    :ok
  end

  test "New starts a sibling thread without stopping the previous session", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    first = session_id(view)
    {:ok, first_pid} = Manager.whereis(first)

    view |> element("#new-session-button") |> render_click()
    second = session_id(view)

    refute second == first
    assert Process.alive?(first_pid)
    assert {:ok, ^first_pid} = Manager.whereis(first)
    assert {:ok, _} = Manager.whereis(second)
    assert has_element?(view, "#thread-#{first}")
    assert has_element?(view, "#thread-#{second}")
  end

  test "the Projects header + starts a thread in the current directory", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    first = session_id(view)
    assert {:ok, %{cwd: cwd}} = Catalog.lookup(first)

    view |> element("#sidebar-new-thread") |> render_click()
    second = session_id(view)

    refute second == first
    assert {:ok, %{cwd: ^cwd}} = Catalog.lookup(second)
    assert has_element?(view, "#thread-#{first}")
    assert has_element?(view, "#thread-#{second}")
  end

  test "a project's + starts a thread in that project's directory", %{conn: conn} do
    other = Path.join(System.tmp_dir!(), "catalyst_project_#{System.unique_integer([:positive])}")
    File.mkdir_p!(other)
    on_exit(fn -> File.rm_rf!(other) end)

    {:ok, view, _html} = live(conn, ~p"/")
    home = session_id(view)
    assert {:ok, %{cwd: home_cwd}} = Catalog.lookup(home)

    # /cd opens a sibling thread elsewhere, so the sidebar lists two projects
    # and the shell's own cwd is no longer the first project's.
    view |> form("#chat-form", %{"message" => "/cd #{other}"}) |> render_submit()
    away = session_id(view)
    refute away == home
    assert {:ok, %{cwd: away_cwd}} = Catalog.lookup(away)
    refute away_cwd == home_cwd

    view |> element("#project-new-thread-#{project_id(home_cwd)}") |> render_click()
    third = session_id(view)

    refute third in [home, away]
    assert {:ok, %{cwd: ^home_cwd}} = Catalog.lookup(third)
    assert has_element?(view, "#thread-#{third}")
  end

  test "switching threads focuses the other session and leaves the first running", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    first = session_id(view)
    submit_prompt(view, "first thread prompt")
    {:ok, first_pid} = Manager.whereis(first)

    view |> element("#new-session-button") |> render_click()
    second = session_id(view)
    refute second == first

    view |> element("#switch-thread-#{first}") |> render_click()

    assert session_id(view) == first
    assert Process.alive?(first_pid)
    assert {:ok, _} = Manager.whereis(second)
    assert has_element?(view, "#message-stream", "first thread prompt")
    assert {:ok, %{title: "first thread prompt"}} = Catalog.lookup(first)
  end

  test "closing a sibling stops it and leaves the current thread", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    first = session_id(view)

    view |> element("#new-session-button") |> render_click()
    second = session_id(view)
    refute second == first

    view |> element("#close-thread-#{first}") |> render_click()

    assert session_id(view) == second
    assert :error = Manager.whereis(first)
    assert {:error, :not_found} = Catalog.lookup(first)
    refute has_element?(view, "#thread-#{first}")
    assert has_element?(view, "#thread-#{second}")
  end

  test "closing the current thread starts a replacement", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    first = session_id(view)

    view |> element("#close-thread-#{first}") |> render_click()
    second = session_id(view)

    refute second == first
    assert :error = Manager.whereis(first)
    assert {:error, :not_found} = Catalog.lookup(first)
    assert {:ok, _} = Manager.whereis(second)
    assert has_element?(view, "#thread-#{second}")
  end

  test "switching to a missing thread leaves the current focus", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    first = session_id(view)

    render_click(view, "switch_session", %{"id" => "does-not-exist"})

    assert session_id(view) == first
    assert has_element?(view, "#thread-#{first}")
  end

  test "the sidebar toggle hides and restores the project list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#shell-sidebar")
    assert has_element?(view, ~s(#sidebar-toggle[aria-pressed="true"]))

    view |> element("#sidebar-toggle") |> render_click()
    refute has_element?(view, "#shell-sidebar")
    assert has_element?(view, ~s(#sidebar-toggle[aria-pressed="false"]))

    view |> element("#sidebar-toggle") |> render_click()
    assert has_element?(view, "#shell-sidebar")
  end

  # The sidebar derives project DOM ids from the catalog, so ask the same
  # projection the LiveView renders from rather than duplicating the hash.
  defp project_id(cwd) do
    {:ok, entries} = Catalog.entries()

    entries
    |> Threads.project(nil)
    |> Map.fetch!(:projects)
    |> Enum.find(&(&1.cwd == cwd))
    |> Map.fetch!(:id)
  end

  defp restore_catalog(nil), do: Application.delete_env(:catalyst, :session_catalog_path)
  defp restore_catalog(path), do: Application.put_env(:catalyst, :session_catalog_path, path)

  defp restore_ui(:not_set), do: :persistent_term.erase(@ui_prefs_ptr)
  defp restore_ui(prefs), do: :persistent_term.put(@ui_prefs_ptr, prefs)
end
