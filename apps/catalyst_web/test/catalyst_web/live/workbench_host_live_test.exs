defmodule CatalystWeb.WorkbenchHostLiveTest do
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Contracts.Workbench.V1
  alias Catalyst.Extension.Manifest
  alias Catalyst.Runtime.{GenerationStore, Generations, Leases}
  alias CatalystWeb.Workbench

  setup do
    :ok = Generations.clear()

    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_workbench_live_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/example.ex"), "hello\n")

    on_exit(fn ->
      Generations.clear()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "the IDE opens, edits, saves, and runs a workspace task", %{conn: conn, root: root} do
    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/ide")

    assert has_element?(view, "#workbench-host[data-workbench-owner=builtin]")
    assert has_element?(view, "#ide-workbench")
    assert has_element?(view, "#workbench-agent-chat-link[href='/']")
    assert has_element?(view, "#workbench-agent-pane-link[href='/']")

    wait_until(fn -> has_element?(view, ~s([data-file-path="lib/example.ex"])) end)
    view |> element(~s([data-file-path="lib/example.ex"])) |> render_click()
    wait_until(fn -> has_element?(view, "#editor-content", "hello") end)

    view
    |> form("#editor-form", %{"editor" => %{"content" => "updated\n"}})
    |> render_change()

    view
    |> form("#editor-form", %{"editor" => %{"content" => "updated\n"}})
    |> render_submit()

    wait_until(fn -> File.read!(Path.join(root, "lib/example.ex")) == "updated\n" end)

    view
    |> form("#terminal-form", %{"terminal" => %{"command" => "printf workbench-ok"}})
    |> render_submit()

    wait_until(fn -> has_element?(view, "#command-output", "workbench-ok") end)

    view |> element("#command-palette-toggle") |> render_click()
    assert has_element?(view, "#command-palette")
    assert has_element?(view, "#palette-chat")
  end

  test "managed workbench replacements apply to new mounts while the old mount stays pinned", %{
    conn: conn,
    root: root
  } do
    first = manifest("test.workbench-a")
    assert {:ok, first_generation} = Generations.install("workbench_source", [first])

    first_conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, first_view, _html} = live(first_conn, "/ide")
    assert has_element?(first_view, "#command-output", "test.workbench-a")

    second = manifest("test.workbench-b")
    assert {:ok, _second_generation} = Generations.install("workbench_source", [second])

    assert has_element?(first_view, "#command-output", "test.workbench-a")
    assert Enum.any?(Leases.list(), &(&1.owner == first_view.pid))
    assert {:ok, %{status: :retiring}} = GenerationStore.fetch(first_generation.id)

    second_conn = build_conn() |> init_test_session(%{"workbench_workspace" => root})
    {:ok, second_view, _html} = live(second_conn, "/ide")
    assert has_element?(second_view, "#command-output", "test.workbench-b")
  end

  test "an invalid managed render target falls back without retaining its lease", %{
    conn: conn,
    root: root
  } do
    broken = manifest("test.workbench-broken")
    assert {:ok, _generation} = Generations.install("workbench_source", [broken])

    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/ide")

    assert has_element?(view, "#workbench-error")
    assert has_element?(view, "#workbench-error-chat-link[href='/']")
    refute Enum.any?(Leases.list(), &(&1.owner == view.pid))
  end

  test "a hanging managed mount is bounded and releases its lease", %{conn: conn, root: root} do
    previous = Application.fetch_env(:catalyst_web, :workbench_callback_timeout)
    Application.put_env(:catalyst_web, :workbench_callback_timeout, 25)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:catalyst_web, :workbench_callback_timeout, value)
        :error -> Application.delete_env(:catalyst_web, :workbench_callback_timeout)
      end
    end)

    hanging = manifest("test.workbench-hanging")
    assert {:ok, _generation} = Generations.install("workbench_source", [hanging])

    conn = init_test_session(conn, %{"workbench_workspace" => root})
    {:ok, view, _html} = live(conn, "/ide")

    assert has_element?(view, "#workbench-error")
    assert has_element?(view, "#workbench-error-reason", "workbench_callback_timeout")
    refute Enum.any?(Leases.list(), &(&1.owner == view.pid))
  end

  defp manifest(id) do
    Manifest.new!(%{
      id: id,
      version: "1.0.0",
      services: [
        %{
          key: Workbench.key(),
          contract: V1.ref(),
          implementation: CatalystWeb.Test.Workbench,
          priority: 900,
          binding: {:pin, :mount}
        }
      ]
    })
  end
end
