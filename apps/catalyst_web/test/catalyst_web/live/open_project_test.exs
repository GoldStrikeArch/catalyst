defmodule CatalystWeb.OpenProjectTest do
  # async: false — writes the shared session catalog and the :folder_picker env.
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Session.Catalog
  alias CatalystWeb.ShellLive.Threads

  setup do
    previous_catalog = Application.get_env(:catalyst, :session_catalog_path)
    previous_picker = Application.get_env(:catalyst_web, :folder_picker, :not_set)

    catalog =
      Path.join(
        System.tmp_dir!(),
        "catalyst_open_project_#{System.unique_integer([:positive])}.json"
      )

    project =
      Path.join(System.tmp_dir!(), "catalyst_project_#{System.unique_integer([:positive])}")

    File.mkdir_p!(project)
    Application.put_env(:catalyst, :session_catalog_path, catalog)
    Application.delete_env(:catalyst_web, :folder_picker)

    on_exit(fn ->
      restore_env(:catalyst, :session_catalog_path, previous_catalog)
      restore_env(:catalyst_web, :folder_picker, previous_picker)
      File.rm(catalog)
      File.rm_rf!(project)
    end)

    %{project: project}
  end

  describe "with a native picker registered (desktop shell)" do
    test "+ opens the dialog from the current cwd and roots a new thread in the chosen folder",
         %{conn: conn, project: project} do
      parent = self()

      Application.put_env(:catalyst_web, :folder_picker, fn start ->
        send(parent, {:dialog_started_at, start})
        {:ok, project}
      end)

      {:ok, view, _html} = live(conn, ~p"/")
      first = session_id(view)
      assert {:ok, %{cwd: first_cwd}} = Catalog.lookup(first)

      view |> element("#sidebar-open-project") |> render_click()
      render_async(view)

      assert_received {:dialog_started_at, ^first_cwd}
      second = session_id(view)
      refute second == first
      assert {:ok, %{cwd: ^project}} = Catalog.lookup(second)
      assert has_element?(view, "##{project_id(project)}")
      assert has_element?(view, "#thread-#{second}")
      assert has_element?(view, "#thread-#{first}")
      refute has_element?(view, "#open-project-form")
      refute has_element?(view, "#sidebar-open-project[disabled]")
    end

    test "cancelling the dialog leaves the current thread alone", %{conn: conn} do
      Application.put_env(:catalyst_web, :folder_picker, fn _start -> :cancelled end)

      {:ok, view, _html} = live(conn, ~p"/")
      first = session_id(view)

      view |> element("#sidebar-open-project") |> render_click()
      render_async(view)

      assert session_id(view) == first
      refute has_element?(view, "#open-project-form")
      refute has_element?(view, "[id$=flash-error]")
    end

    test "a failing dialog reports the error and re-enables the button", %{conn: conn} do
      Application.put_env(:catalyst_web, :folder_picker, fn _start -> {:error, :no_display} end)

      {:ok, view, _html} = live(conn, ~p"/")
      first = session_id(view)

      view |> element("#sidebar-open-project") |> render_click()
      render_async(view)

      assert session_id(view) == first
      assert has_element?(view, "[id$=flash-error]", "Could not open the folder picker")
      refute has_element?(view, "#sidebar-open-project[disabled]")
    end

    test "a crashing dialog is reported the same way", %{conn: conn} do
      Application.put_env(:catalyst_web, :folder_picker, fn _start -> raise "wx exploded" end)

      {:ok, view, _html} = live(conn, ~p"/")
      first = session_id(view)

      view |> element("#sidebar-open-project") |> render_click()
      render_async(view)

      assert session_id(view) == first
      assert has_element?(view, "[id$=flash-error]", "Could not open the folder picker")
    end
  end

  describe "without a native picker (browser mode)" do
    test "+ reveals a path form; submitting an existing folder roots a new thread there",
         %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/")
      first = session_id(view)
      refute has_element?(view, "#open-project-form")

      view |> element("#sidebar-open-project") |> render_click()
      assert has_element?(view, "#open-project-form")

      view |> form("#open-project-form", %{"path" => project}) |> render_submit()

      second = session_id(view)
      refute second == first
      assert {:ok, %{cwd: ^project}} = Catalog.lookup(second)
      assert has_element?(view, "##{project_id(project)}")
      refute has_element?(view, "#open-project-form")
    end

    test "~ and relative paths resolve like /cd", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/")
      first = session_id(view)
      assert {:ok, %{cwd: first_cwd}} = Catalog.lookup(first)
      relative = Path.relative_to(project, first_cwd)

      view |> element("#sidebar-open-project") |> render_click()
      view |> form("#open-project-form", %{"path" => relative}) |> render_submit()

      assert {:ok, %{cwd: ^project}} = Catalog.lookup(session_id(view))
    end

    test "a missing folder keeps the form open with an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      first = session_id(view)

      view |> element("#sidebar-open-project") |> render_click()
      view |> form("#open-project-form", %{"path" => "/definitely/not/here"}) |> render_submit()

      assert session_id(view) == first
      assert has_element?(view, "#open-project-form")
      assert has_element?(view, "[id$=flash-error]", "Not a directory")

      view |> form("#open-project-form", %{"path" => "   "}) |> render_submit()
      assert has_element?(view, "[id$=flash-error]", "Enter a project folder path")
    end

    test "cancel closes the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#sidebar-open-project") |> render_click()
      assert has_element?(view, "#open-project-form")

      view |> element("#open-project-cancel") |> render_click()
      refute has_element?(view, "#open-project-form")
    end
  end

  defp project_id(cwd) do
    {:ok, entries} = Catalog.entries()

    entries
    |> Threads.project(nil)
    |> Map.fetch!(:projects)
    |> Enum.find(&(&1.cwd == cwd))
    |> Map.fetch!(:id)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, :not_set), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
