defmodule CatalystWeb.WorkflowPickerTest do
  # async: false — writes the shared workflow prefs persistent term and the
  # singleton workflow registry.
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Session.{Manager, Server}
  alias Catalyst.Workflow.Registry, as: WorkflowRegistry

  @workflow_prefs_ptr {CatalystWeb.ShellLive, :workflow_prefs}

  defmodule StubWorkflow do
    @moduledoc false
    @behaviour Catalyst.Workflow

    @impl true
    def run(_prompts, context, _config, _emit), do: {:ok, [], context}
  end

  setup do
    previous_prefs = :persistent_term.get(@workflow_prefs_ptr, :not_set)
    :persistent_term.erase(@workflow_prefs_ptr)

    owner = "workflow_picker_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      WorkflowRegistry.unregister_owner(owner)
      restore_prefs(previous_prefs)
    end)

    {:ok, owner: owner}
  end

  defp restore_prefs(:not_set), do: :persistent_term.erase(@workflow_prefs_ptr)
  defp restore_prefs(prefs), do: :persistent_term.put(@workflow_prefs_ptr, prefs)

  defp session_pid(view) do
    {:ok, pid} = Manager.whereis(session_id(view))
    pid
  end

  test "picker includes persisted built-in templates", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#workflow-form")
    assert has_element?(view, "#workflow-select option[value='research']", "(template)")
    assert has_element?(view, "#workflow-select option[value='build-review']", "(template)")
    assert has_element?(view, "#workflow-select option[value='secure-build']", "(template)")
  end

  test "selecting a workflow configures the live session and new sessions inherit it", %{
    conn: conn,
    owner: owner
  } do
    :ok = WorkflowRegistry.register_workflow("review", StubWorkflow, owner: owner)

    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#workflow-form")
    assert has_element?(view, "#workflow-select option[value='review']", "(extension)")

    pid = session_pid(view)
    refute Keyword.has_key?(Server.state(pid).opts, :workflow)

    view |> form("#workflow-form") |> render_change(%{"workflow" => "review"})

    # Reconfigured in place: same session process, next run gets the workflow.
    assert session_pid(view) == pid
    assert Server.state(pid).opts[:workflow] == "review"
    assert has_element?(view, "#workflow-select option[value='review'][selected]")

    # A NEW session starts with the persisted preference.
    view |> element("#new-session-button") |> render_click()
    new_pid = session_pid(view)
    refute new_pid == pid
    assert Server.state(new_pid).opts[:workflow] == "review"

    # The empty value returns to the default chain and DELETES the key.
    view |> form("#workflow-form") |> render_change(%{"workflow" => ""})
    refute Keyword.has_key?(Server.state(new_pid).opts, :workflow)
  end

  test "an unresolvable selection is rejected with a flash and changes nothing", %{
    conn: conn,
    owner: owner
  } do
    :ok = WorkflowRegistry.register_workflow("review", StubWorkflow, owner: owner)
    :ok = WorkflowRegistry.register_workflow("doomed", StubWorkflow, owner: owner)

    {:ok, view, _html} = live(conn, "/")
    pid = session_pid(view)

    view |> form("#workflow-form") |> render_change(%{"workflow" => "review"})
    assert Server.state(pid).opts[:workflow] == "review"

    # Purged between the render and the pick: the rendered select still lists
    # "doomed", but selecting it must be rejected by live validation.
    :ok = WorkflowRegistry.unregister_workflow("doomed")

    html = view |> form("#workflow-form") |> render_change(%{"workflow" => "doomed"})
    assert html =~ "no longer available"

    assert Server.state(pid).opts[:workflow] == "review"
    assert :persistent_term.get(@workflow_prefs_ptr) == %{workflow: "review"}
  end

  test "a persistence failure is shown without changing the preference or session", %{
    conn: conn,
    owner: owner
  } do
    :ok = WorkflowRegistry.register_workflow("review", StubWorkflow, owner: owner)

    {:ok, view, _html} = live(conn, "/")
    pid = session_pid(view)
    store_path = Server.state(pid).store_path
    original = File.read!(store_path)

    on_exit(fn ->
      File.rm_rf!(store_path)
      File.mkdir_p!(Path.dirname(store_path))
      File.write!(store_path, original)
    end)

    File.rm!(store_path)
    File.mkdir_p!(store_path)

    html = view |> form("#workflow-form") |> render_change(%{"workflow" => "review"})

    assert html =~ "could not select workflow"
    assert :persistent_term.get(@workflow_prefs_ptr) == %{workflow: nil}
    refute Keyword.has_key?(Server.state(pid).opts, :workflow)
    assert has_element?(view, "#workflow-select option[value=''][selected]")
  end

  test "a selected workflow purged from the registry stays visible as unavailable", %{
    conn: conn,
    owner: owner
  } do
    :ok = WorkflowRegistry.register_workflow("review", StubWorkflow, owner: owner)

    {:ok, view, _html} = live(conn, "/")
    pid = session_pid(view)

    view |> form("#workflow-form") |> render_change(%{"workflow" => "review"})
    assert Server.state(pid).opts[:workflow] == "review"

    :ok = WorkflowRegistry.unregister_owner(owner)

    # The next chrome refresh (patch navigation) recomputes the options; the
    # vanished selection must stay visible — and selected — rather than letting
    # the browser silently display another workflow.
    view |> render_patch("/")
    assert has_element?(view, "#workflow-select option[value='review'][selected]", "unavailable")

    # The live session still carries the name (its next run reports the error);
    # picking default recovers from the header.
    assert Server.state(pid).opts[:workflow] == "review"
    view |> form("#workflow-form") |> render_change(%{"workflow" => ""})
    refute Keyword.has_key?(Server.state(pid).opts, :workflow)
  end

  test "a stale saved preference self-heals when starting a session", %{conn: conn} do
    :persistent_term.put(@workflow_prefs_ptr, %{workflow: "ghost"})

    {:ok, view, _html} = live(conn, "/")

    # The unknown name was dropped from start opts (it would fail every run)
    # and the preference reconciled to default while valid templates remain.
    refute Keyword.has_key?(Server.state(session_pid(view)).opts, :workflow)
    assert :persistent_term.get(@workflow_prefs_ptr) == %{workflow: nil}
    assert has_element?(view, "#workflow-select option[value=''][selected]")
    refute has_element?(view, "#workflow-select option[value='ghost']")
  end
end
