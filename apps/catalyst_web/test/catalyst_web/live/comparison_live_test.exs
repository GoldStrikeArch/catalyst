defmodule CatalystWeb.ComparisonLiveTest do
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Comparison
  alias Catalyst.{Content, Message}
  alias Catalyst.LLM.ProviderConfig
  alias Catalyst.LLM.Registry, as: LLMRegistry
  alias Catalyst.Model
  alias Catalyst.Session.{Manager, Server}

  defmodule ThirdProvider do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(_model, _context, _opts, _sink), do: {:error, :unused}
  end

  defmodule ThirdCatalog do
    @behaviour Catalyst.LLM.ModelCatalog

    @entry %{
      id: "third-ui-model",
      name: "Third UI Model",
      efforts: ["low", "medium"],
      default_effort: "low",
      context_window: 32_000
    }

    @impl true
    def default_model_id, do: @entry.id

    @impl true
    def catalog_snapshot(id) do
      selected = if id == @entry.id, do: @entry, else: %{@entry | id: id, name: id}
      models = if id == @entry.id, do: [@entry], else: [@entry, selected]
      %{models: models, selected: selected}
    end

    @impl true
    def model(id), do: %Model{id: id, api: "third-ui-api", provider: "third-ui"}
  end

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

  test "a catalog-registered third provider appears and configures without UI branches", %{
    conn: conn,
    source: source
  } do
    register_third_provider()

    assert {:ok, comparison} =
             Comparison.create(source, ["gpt-5.6-sol", "gpt-5.6-terra"])

    lane = hd(comparison["lanes"])
    assert {:ok, view, _html} = live(conn, ~p"/compare/#{comparison["id"]}")
    assert has_element?(view, "#add-lane-model option[value='third-ui-model']")

    lane_view = find_live_child(view, "comparison-lane-live-#{lane["id"]}")

    lane_view
    |> form("#lane-config-form-#{lane["id"]}", %{
      "config" => %{
        "model" => "third-ui-model",
        "effort" => "low",
        "workflow" => "",
        "system_prompt" => "Third provider prompt."
      }
    })
    |> render_submit()

    assert {:ok, updated} = Comparison.get(comparison["id"])
    assert {:ok, configured} = Comparison.lane(updated, lane["id"])
    assert configured["provider_id"] == "third-ui"
    assert configured["model_id"] == "third-ui-model"
    assert has_element?(lane_view, "#lane-effort-#{lane["id"]} option[value='low']")
    refute has_element?(lane_view, "#lane-effort-#{lane["id"]} option[value='high']")
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

  defp register_third_provider do
    on_exit(fn -> LLMRegistry.unregister_provider("third-ui-api") end)

    assert :ok =
             LLMRegistry.register_provider(
               "third-ui-api",
               %ProviderConfig{
                 id: "third-ui",
                 module: ThirdProvider,
                 name: "Third UI",
                 catalog: ThirdCatalog
               }
             )
  end
end
