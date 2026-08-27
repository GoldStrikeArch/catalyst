defmodule CatalystWeb.ComparisonLiveTest do
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Comparison
  alias Catalyst.{Content, Message}
  alias Catalyst.Session.{Catalog, Manager, Server, Store}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "catalyst_comparison_live_#{System.unique_integer([:positive])}"
      )

    source = Path.join(tmp, "source")
    File.mkdir_p!(source)
    git!(source, ["init", "-b", "main"])
    File.write!(Path.join(source, "README.md"), "# Comparison\n")
    git!(source, ["add", "README.md"])

    git!(source, [
      "-c",
      "user.name=Catalyst",
      "-c",
      "user.email=test@example.com",
      "commit",
      "-m",
      "initial"
    ])

    previous = %{
      comparisons: Application.get_env(:catalyst, :comparisons_root),
      workspaces: Application.get_env(:catalyst, :workspaces_root),
      sessions: Application.get_env(:catalyst, :sessions_root)
    }

    Application.put_env(:catalyst, :comparisons_root, Path.join(tmp, "comparisons"))
    Application.put_env(:catalyst, :workspaces_root, Path.join(tmp, "workspaces"))
    Application.put_env(:catalyst, :sessions_root, Path.join(tmp, "sessions"))

    on_exit(fn ->
      Comparison.list()
      |> Enum.flat_map(& &1["lanes"])
      |> Enum.each(&Manager.stop(&1["session_id"]))

      restore(:comparisons_root, previous.comparisons)
      restore(:workspaces_root, previous.workspaces)
      restore(:sessions_root, previous.sessions)
      File.rm_rf!(tmp)
    end)

    {:ok, source: source}
  end

  test "renders independent lanes and dispatches one shared prompt", %{conn: conn, source: source} do
    assert {:ok, comparison} =
             Comparison.create(source, ["gpt-5.6-sol", "gpt-5.6-terra"])

    Enum.each(comparison["lanes"], fn lane ->
      Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(lane["session_id"]))
    end)

    assert {:ok, view, _html} = live(conn, ~p"/compare/#{comparison["id"]}")
    assert has_element?(view, "#comparison-lanes")
    assert has_element?(view, "[data-comparison-lane]")
    assert has_element?(view, "#shared-prompt-form")

    lane_ids = Enum.map(comparison["lanes"], & &1["id"])

    view
    |> form("#shared-prompt-form", %{
      "shared" => %{"message" => "Compare this project", "lanes" => lane_ids}
    })
    |> render_submit()

    Enum.each(comparison["lanes"], fn lane ->
      id = lane["session_id"]
      assert_receive {:agent_event, ^id, %Catalyst.Agent.Event.AgentEnd{}}, 5_000
    end)
  end

  test "lane settings persist and refresh the shared recipient label", %{
    conn: conn,
    source: source
  } do
    assert {:ok, comparison} =
             Comparison.create(source, ["gpt-5.6-sol", "gpt-5.6-terra"])

    lane = hd(comparison["lanes"])
    assert {:ok, view, _html} = live(conn, ~p"/compare/#{comparison["id"]}")
    lane_view = find_live_child(view, "comparison-lane-live-#{lane["id"]}")

    lane_view
    |> form("#lane-config-form-#{lane["id"]}", %{
      "config" => %{
        "model" => "gpt-5.6-luna",
        "effort" => "high",
        "workflow" => "",
        "system_prompt" => "Review only correctness."
      }
    })
    |> render_submit()

    assert {:ok, updated} = Comparison.get(comparison["id"])
    assert {:ok, configured} = Comparison.lane(updated, lane["id"])
    assert configured["model_id"] == "gpt-5.6-luna"
    assert configured["reasoning_effort"] == "high"
    assert configured["workflow"] == nil

    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#shared-lane-label-#{lane["id"]}", "gpt-5.6-luna")

    assert has_element?(
             lane_view,
             "#flash-group-lane-#{lane["id"]}-flash-info",
             "Lane settings apply"
           )
  end

  test "a stopped lane disables controls and can be explicitly reattached", %{
    conn: conn,
    source: source
  } do
    assert {:ok, comparison} =
             Comparison.create(source, ["gpt-5.6-sol", "gpt-5.6-terra"])

    lane = hd(comparison["lanes"])
    assert {:ok, old_pid} = Manager.whereis(lane["session_id"])
    old_ref = Process.monitor(old_pid)
    assert {:ok, view, _html} = live(conn, ~p"/compare/#{comparison["id"]}")
    lane_view = find_live_child(view, "comparison-lane-live-#{lane["id"]}")

    :ok = Manager.stop(lane["session_id"])
    assert_receive {:DOWN, ^old_ref, :process, ^old_pid, :shutdown}, 1_000
    _ = :sys.get_state(lane_view.pid)

    assert has_element?(lane_view, "#lane-disconnected-#{lane["id"]}")
    assert has_element?(lane_view, "#lane-prompt-submit-#{lane["id"]}[disabled]")

    lane_view
    |> element("#lane-retry-#{lane["id"]}")
    |> render_click()

    refute has_element?(lane_view, "#lane-disconnected-#{lane["id"]}")
    refute has_element?(lane_view, "#lane-prompt-submit-#{lane["id"]}[disabled]")
    assert {:ok, new_pid} = Manager.whereis(lane["session_id"])
    refute new_pid == old_pid
  end

  test "a snapshot-covered MessageEnd is not rendered twice", %{conn: conn, source: source} do
    assert {:ok, comparison} =
             Comparison.create(source, ["gpt-5.6-sol", "gpt-5.6-terra"])

    lane = hd(comparison["lanes"])
    lane_session_id = lane["session_id"]
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(lane_session_id))
    assert {:ok, view, _html} = live(conn, ~p"/compare/#{comparison["id"]}")
    lane_view = find_live_child(view, "comparison-lane-live-#{lane["id"]}")

    lane_view
    |> form("#lane-prompt-form-#{lane["id"]}", %{"prompt" => %{"message" => "Compare this"}})
    |> render_submit()

    assert_receive {:agent_event, ^lane_session_id, %Catalyst.Agent.Event.AgentEnd{}}, 5_000

    assert {:ok, pid} = Manager.whereis(lane["session_id"])
    messages = Server.state(pid).messages
    count = length(messages)
    last = List.last(messages)
    assert {:ok, replayed_view, _html} = live(conn, ~p"/compare/#{comparison["id"]}")

    lane_view =
      find_live_child(replayed_view, "comparison-lane-live-#{lane["id"]}")

    _ = :sys.get_state(lane_view.pid)
    assert has_element?(lane_view, "#lane-#{lane["id"]}-message-#{count}")

    send(
      lane_view.pid,
      {:agent_event, lane_session_id,
       %Catalyst.Agent.Event.MessageEnd{
         message: last
       }}
    )

    _ = :sys.get_state(lane_view.pid)
    refute has_element?(lane_view, "#lane-#{lane["id"]}-message-#{count + 1}")

    fresh = %Message.User{content: Content.text("genuinely new")}

    send(
      lane_view.pid,
      {:agent_event, lane_session_id,
       %Catalyst.Agent.Event.MessageEnd{
         message: fresh
       }}
    )

    _ = :sys.get_state(lane_view.pid)
    assert has_element?(lane_view, "#lane-#{lane["id"]}-message-#{count + 1}", "genuinely new")
  end

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git exited #{status}: #{output}")
    end
  end

  defp restore(key, nil), do: Application.delete_env(:catalyst, key)
  defp restore(key, value), do: Application.put_env(:catalyst, key, value)

  describe "new comparison project chooser" do
    setup %{source: source} do
      previous = Application.get_env(:catalyst, :session_catalog_path)

      catalog =
        Path.join(
          System.tmp_dir!(),
          "catalyst_cmp_catalog_#{System.unique_integer([:positive])}.json"
        )

      Application.put_env(:catalyst, :session_catalog_path, catalog)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:catalyst, :session_catalog_path)
          path -> Application.put_env(:catalyst, :session_catalog_path, path)
        end

        File.rm(catalog)
      end)

      %{source: source}
    end

    test "with no known projects the directory is a free-form field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/compare")

      assert has_element?(view, "input#comparison-source[type=text]")
      refute has_element?(view, "select#comparison-source")
    end

    test "known projects are offered in a select with the most recent one preselected",
         %{conn: conn, source: source} do
      other = Path.join(Path.dirname(source), "another_project")
      File.mkdir_p!(other)
      remember!(other, "cmp-other")
      remember!(source, "cmp-source")

      {:ok, view, _html} = live(conn, ~p"/compare")

      assert has_element?(view, "select#comparison-source")
      assert has_element?(view, ~s(#comparison-source option[value="#{source}"][selected]))
      assert has_element?(view, ~s(#comparison-source option[value="#{other}"]))
      assert has_element?(view, ~s(#comparison-source option[value="__other__"]))
      refute has_element?(view, "#comparison-source-other")
    end

    test "choosing 'Other folder…' reveals a path field that feeds creation",
         %{conn: conn, source: source} do
      remember!(source, "cmp-source")
      {:ok, view, _html} = live(conn, ~p"/compare")

      view
      |> form("#create-comparison-form", %{"comparison" => %{"source" => "__other__"}})
      |> render_change()

      assert has_element?(view, "#comparison-source-other")

      not_a_repo = Path.join(Path.dirname(source), "plain_dir")
      File.mkdir_p!(not_a_repo)

      view
      |> form("#create-comparison-form", %{
        "comparison" => %{"source" => "__other__", "source_other" => not_a_repo}
      })
      |> render_submit()

      render_async(view)
      assert has_element?(view, "[id$=flash-error]", "Comparison failed")
      assert Comparison.list() == []
    end

    defp remember!(cwd, id) do
      {:ok, _handle} = Store.open(cwd, id: id)
      :ok = Catalog.remember(id, cwd)
    end
  end
end
