defmodule CatalystWeb.SessionCatalogResumeTest do
  # async: false — toggles global reattach/catalog config and :persistent_term.
  use CatalystWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Catalyst.Session.{Catalog, Manager}

  @session_ptr {CatalystWeb.ShellLive, :current_session}

  test "after a simulated VM restart the shell resumes the persisted {id, cwd}", %{conn: conn} do
    # Clean slate: no live pointer, an isolated catalog, reattach enabled.
    :persistent_term.erase(@session_ptr)
    Application.put_env(:catalyst_web, :reattach_sessions, true)

    catalog =
      Path.join(
        System.tmp_dir!(),
        "catalyst_catalog_resume_#{System.unique_integer([:positive])}.json"
      )

    Application.put_env(:catalyst, :session_catalog_path, catalog)

    on_exit(fn ->
      Application.put_env(:catalyst_web, :reattach_sessions, false)
      Application.delete_env(:catalyst, :session_catalog_path)
      :persistent_term.erase(@session_ptr)
      File.rm(catalog)
    end)

    {:ok, view, _html} = live(conn, ~p"/legacy-chat")
    id = session_id(view)
    submit_prompt(view, "list the files")
    assert has_element?(view, "#message-stream", "list the files")

    # The attach wrote the exact {id, cwd} pair through to the catalog.
    assert {:ok, %{id: ^id, cwd: cwd}} = Catalog.lookup(id)
    assert File.dir?(cwd)

    # Simulate a full VM restart: the session process dies and the
    # :persistent_term pointer is gone. Only disk state (store + catalog)
    # survives.
    {:ok, pid} = Manager.whereis(id)
    ref = Process.monitor(pid)
    :ok = Manager.stop(id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    :persistent_term.erase(@session_ptr)

    # A fresh mount discovers the catalog entry, resumes the same session id
    # at the same cwd, and replays the persisted transcript.
    {:ok, view2, _html} = live(conn, ~p"/legacy-chat")
    assert session_id(view2) == id

    assert has_element?(view2, "#message-stream", "list the files")
    assert has_element?(view2, "#message-stream", "offline Demo provider")
    refute has_element?(view2, "#chat-empty-state")

    assert {:ok, %{id: ^id, cwd: ^cwd}} = Catalog.most_recent()
  end
end
