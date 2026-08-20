defmodule CatalystWeb.ComparisonLiveTest do
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Comparison
  alias Catalyst.Session.Server

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

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git exited #{status}: #{output}")
    end
  end

  defp restore(key, nil), do: Application.delete_env(:catalyst, key)
  defp restore(key, value), do: Application.put_env(:catalyst, key, value)
end
