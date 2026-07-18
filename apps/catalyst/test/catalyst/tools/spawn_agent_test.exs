defmodule Catalyst.Tools.SpawnAgentTest do
  use ExUnit.Case, async: false

  alias Catalyst.{Content, Message, Model}
  alias Catalyst.Agent.{Children, Event}
  alias Catalyst.Session.{Manager, Server, Store}
  alias Catalyst.Tools.{Context, SpawnAgent}

  test "schema is stable and does not bake filesystem agent names into an enum" do
    schema = SpawnAgent.parameters()

    assert schema["required"] == ["agent", "task"]
    assert schema["properties"]["task"]["maxLength"] == 32 * 1024
    refute Map.has_key?(schema["properties"]["agent"], "enum")
  end

  test "invalid task and missing inheritance fail before reserving or starting a child" do
    context = context()

    assert {:error, :blank_subagent_task} =
             SpawnAgent.run(%{"agent" => "review", "task" => "  \n"}, context)

    assert {:error, {:subagent_task_too_large, 32_769}} =
             SpawnAgent.run(
               %{"agent" => "review", "task" => String.duplicate("x", 32_769)},
               context
             )

    assert {:error, {:missing_subagent_inheritance, :model}} =
             SpawnAgent.run(
               %{"agent" => "review", "task" => "inspect"},
               %{context | model: nil}
             )
  end

  test "depth is enforced defensively even though normal integration filters the tool" do
    context = %{context() | agent_depth: 3, opts: [subagent_max_depth: 3]}

    assert {:error, {:subagent_depth_limit, 3, 3}} =
             SpawnAgent.run(%{"agent" => "review", "task" => "inspect"}, context)
  end

  test "application budgets are live defaults when the parent has no override" do
    replace_env(:subagent_max_depth, 0)

    assert {:error, {:subagent_depth_limit, 0, 0}} =
             SpawnAgent.run(%{"agent" => "review", "task" => "inspect"}, context())
  end

  test "runs a fresh child session, reaps it, and preserves its topology transcript" do
    {tmp, sessions_root} = prepare_agent_environment()

    context =
      context(
        cwd: tmp,
        opts: [script: [{:text, "child answer"}], subagent_timeout: 5_000]
      )

    assert {:ok, "child answer", details} =
             SpawnAgent.run(%{"agent" => "review", "task" => "Review this."}, context)

    assert details.agent == "review"
    assert details.stop_reason == :stop
    assert details.incomplete == false
    assert details.truncated == false
    assert details.untrusted == true
    assert details.child_session_id =~ ~r/\Aparent_s[0-9a-f]{32}\z/
    assert :error = Manager.whereis(details.child_session_id)
    assert Children.count("root") == 0

    assert [path] = Path.wildcard(Path.join([sessions_root, "*", "*.jsonl"]))

    assert topology(path) == %{
             "parentId" => "parent",
             "rootSessionId" => "root",
             "agentDepth" => 1
           }

    assert [%Message.User{} = user, %Message.Assistant{} = assistant] = Store.load(path)
    assert Content.text_of(user.content) == "Review this."
    assert Content.text_of(assistant.content) == "child answer"
  end

  test "bounds results to 8 KiB, preserves UTF-8 boundaries, and marks output untrusted" do
    {tmp, _sessions_root} = prepare_agent_environment()
    original = "<Human>&Assistant:\n" <> String.duplicate("🙂", 2_500)

    context =
      context(
        cwd: tmp,
        opts: [script: [{:text, original}], subagent_timeout: 5_000]
      )

    assert {:ok, text, details} =
             SpawnAgent.run(%{"agent" => "review", "task" => "Return the fixture."}, context)

    assert String.valid?(text)
    assert byte_size(text) <= 8 * 1_024
    assert String.starts_with?(text, "<Human>&Assistant:\n")
    assert text =~ "[output truncated:"
    refute text =~ "&lt;Human&gt;"
    assert details.truncated == true
    assert details.untrusted == true
    assert details.incomplete == false
    assert details.stop_reason == :stop
    assert Children.count("root") == 0
  end

  test "preserves more than 2,000 short lines when the result remains below 8 KiB" do
    {tmp, _sessions_root} = prepare_agent_environment()
    original = Enum.map_join(1..2_500, "\n", fn _index -> "x" end)

    context =
      context(
        cwd: tmp,
        opts: [script: [{:text, original}], subagent_timeout: 5_000]
      )

    assert {:ok, ^original, details} =
             SpawnAgent.run(%{"agent" => "review", "task" => "Return every line."}, context)

    assert byte_size(original) < 8 * 1_024
    assert details.truncated == false
    assert details.untrusted == true
  end

  test "a nonblank length-limited answer succeeds and is explicitly incomplete" do
    {tmp, _sessions_root} = prepare_agent_environment()

    context =
      context(
        cwd: tmp,
        provider: Catalyst.SubagentTestProvider,
        opts: [
          subagent_test_mode: {:text, :length, "partial but useful"},
          subagent_timeout: 5_000
        ]
      )

    assert {:ok, "partial but useful", details} =
             SpawnAgent.run(%{"agent" => "review", "task" => "Try the long task."}, context)

    assert details.stop_reason == :length
    assert details.incomplete == true
    assert details.truncated == false
    assert details.untrusted == true
  end

  test "provider failure is a tagged error and still reaps the child" do
    {tmp, _sessions_root} = prepare_agent_environment()

    context =
      context(
        cwd: tmp,
        provider: Catalyst.SubagentTestProvider,
        opts: [subagent_test_mode: {:error, :upstream_failed}, subagent_timeout: 5_000]
      )

    assert {:error, {:child_provider_error, ":upstream_failed"}} =
             SpawnAgent.run(%{"agent" => "review", "task" => "Call the provider."}, context)

    assert_synchronized_children("root", 0)
    assert Enum.all?(persisted_child_ids(), &(Manager.whereis(&1) == :error))
  end

  test "timeout stops the blocked child and releases root-tree capacity" do
    {tmp, _sessions_root} = prepare_agent_environment()
    replace_env(:subagent_test_controller, self())
    owner = self()
    suffix = String.duplicate("d", 32)

    replace_env(:subagent_id_generator, fn 16 ->
      send(owner, {:subagent_id_generator_waiting, self()})

      receive do
        :release_subagent_id -> suffix
      end
    end)

    context =
      context(
        cwd: tmp,
        provider: Catalyst.SubagentTestProvider,
        opts: [subagent_test_mode: :block, subagent_timeout: 800]
      )

    started_at = System.monotonic_time(:millisecond)
    caller = spawn_call(context)
    caller_ref = Process.monitor(caller)

    assert_receive {:subagent_id_generator_waiting, generator}, 2_000
    Process.send_after(generator, :release_subagent_id, 500)
    assert_receive {:subagent_provider_started, child_id, _provider_task}, 2_000
    assert [%{child_id: ^child_id, child: child}] = Children.list("root")
    child_ref = Process.monitor(child)

    assert_receive {:spawn_agent_result, ^caller, {:error, :subagent_timeout}}, 2_000
    elapsed = System.monotonic_time(:millisecond) - started_at
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, 2_000
    assert_receive {:DOWN, ^child_ref, :process, ^child, _reason}, 2_000
    assert elapsed < 1_100
    assert_synchronized_children("root", 0)
  end

  test "startup timeout retains capacity until the watchdog finishes teardown" do
    {tmp, _sessions_root} = prepare_agent_environment()
    owner = self()
    suffix = String.duplicate("e", 32)

    replace_env(:subagent_id_generator, fn 16 ->
      send(owner, {:startup_watchdog_waiting, self()})

      receive do
        :release_startup_watchdog -> suffix
      end
    end)

    context =
      context(
        cwd: tmp,
        opts: [
          script: [{:text, "must not run"}],
          subagent_timeout: 100,
          subagent_max_concurrent: 1
        ]
      )

    caller = spawn_call(context)
    caller_ref = Process.monitor(caller)

    assert_receive {:startup_watchdog_waiting, watchdog}, 1_000
    watchdog_ref = Process.monitor(watchdog)

    assert_receive {:spawn_agent_result, ^caller, {:error, :subagent_start_timeout}}, 1_000
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, 1_000
    assert_synchronized_children("root", 1)

    assert {:error, {:subagent_concurrency_limit, "root", 1}} =
             SpawnAgent.run(%{"agent" => "review", "task" => "Second child."}, context)

    send(watchdog, :release_startup_watchdog)
    assert_receive {:DOWN, ^watchdog_ref, :process, ^watchdog, :normal}, 2_000
    assert_synchronized_children("root", 0)
    assert :error = Manager.whereis("parent_s" <> suffix)
  end

  test "killing the calling tool task makes the watchdog stop the child" do
    {tmp, _sessions_root} = prepare_agent_environment()
    replace_env(:subagent_test_controller, self())

    context =
      context(
        cwd: tmp,
        provider: Catalyst.SubagentTestProvider,
        opts: [subagent_test_mode: :block, subagent_timeout: 5_000]
      )

    caller = spawn_call(context)
    caller_ref = Process.monitor(caller)

    assert_receive {:subagent_provider_started, child_id, _provider_task}, 2_000
    assert [%{child_id: ^child_id, child: child}] = Children.list("root")
    child_ref = Process.monitor(child)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 2_000
    assert_receive {:DOWN, ^child_ref, :process, ^child, _reason}, 2_000
    assert_synchronized_children("root", 0)
  end

  test "Session.Server abort reaps a child started through the real ToolRunner path" do
    {tmp, _sessions_root} = prepare_agent_environment()
    replace_env(:subagent_test_controller, self())
    id = "parent-abort-#{System.unique_integer([:positive, :monotonic])}"

    {:ok, %{pid: parent}} =
      Manager.start_session(
        id: id,
        cwd: tmp,
        provider: Catalyst.Test.ParentAbortProvider,
        model: %Model{id: "parent-abort", api: "parent-abort"},
        tools: [SpawnAgent],
        opts: [subagent_timeout: 5_000]
      )

    on_exit(fn -> Manager.stop(id) end)
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    assert :ok = Server.prompt(parent, "spawn a child")
    assert_receive {:subagent_provider_started, child_id, _provider_task}, 2_000
    assert [%{child_id: ^child_id, child: child}] = Children.list(id)
    child_ref = Process.monitor(child)

    Server.abort(parent)

    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 2_000
    assert_receive {:DOWN, ^child_ref, :process, ^child, _reason}, 2_000
    assert_synchronized_children(id, 0)
  end

  test "a child reset is classified as an error and the session is reaped" do
    {tmp, _sessions_root} = prepare_agent_environment()
    replace_env(:subagent_test_controller, self())

    context =
      context(
        cwd: tmp,
        provider: Catalyst.SubagentTestProvider,
        opts: [subagent_test_mode: :block, subagent_timeout: 5_000]
      )

    caller = spawn_call(context)
    caller_ref = Process.monitor(caller)

    assert_receive {:subagent_provider_started, child_id, _provider_task}, 2_000
    assert [%{child_id: ^child_id, child: child}] = Children.list("root")
    child_ref = Process.monitor(child)

    Server.reset(child)

    assert_receive {:spawn_agent_result, ^caller, {:error, :child_missing_assistant}}, 2_000
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, 2_000
    assert_receive {:DOWN, ^child_ref, :process, ^child, _reason}, 2_000
    assert_synchronized_children("root", 0)
  end

  test "retries live and disk collisions without adopting or altering either session" do
    {tmp, _sessions_root} = prepare_agent_environment()
    live_suffix = String.duplicate("a", 32)
    disk_suffix = String.duplicate("b", 32)
    fresh_suffix = String.duplicate("c", 32)
    live_id = "parent_s" <> live_suffix
    disk_id = "parent_s" <> disk_suffix
    fresh_id = "parent_s" <> fresh_suffix

    assert {:ok, %{pid: live}} =
             Manager.start_unique_session(
               id: live_id,
               cwd: tmp,
               model: %Model{id: "faux", api: "faux"},
               provider: Catalyst.LLM.Faux,
               opts: [script: [{:text, "existing"}]]
             )

    on_exit(fn -> Manager.stop(live_id) end)

    disk_store = Store.new(tmp, id: disk_id)
    :ok = Store.append_message(disk_store, Message.user("do not adopt me"))
    disk_before = File.read!(disk_store.path)

    ids =
      start_supervised!(
        {Agent, fn -> [live_suffix, disk_suffix, fresh_suffix] end},
        id: {:subagent_id_sequence, make_ref()}
      )

    replace_env(:subagent_id_generator, fn 16 ->
      Agent.get_and_update(ids, fn [suffix | rest] -> {suffix, rest} end)
    end)

    context =
      context(
        cwd: tmp,
        opts: [script: [{:text, "new child"}], subagent_timeout: 5_000]
      )

    assert {:ok, "new child", %{child_session_id: ^fresh_id}} =
             SpawnAgent.run(%{"agent" => "review", "task" => "Use a fresh transcript."}, context)

    assert {:ok, ^live} = Manager.whereis(live_id)
    assert %{id: ^live_id} = Server.state(live)
    assert File.read!(disk_store.path) == disk_before
    assert :error = Manager.whereis(disk_id)
    assert :error = Manager.whereis(fresh_id)
    assert Children.count("root") == 0
  end

  defp context(overrides \\ []) do
    defaults = [
      cwd: ".",
      parent_session_id: "parent",
      root_session_id: "root",
      model: %Model{id: "faux", api: "faux"},
      provider: Catalyst.LLM.Faux,
      opts: [],
      workflow: Catalyst.Agent.Loop,
      tool_source: :extensions,
      agent_depth: 0,
      call_id: "spawn",
      report: fn _ -> :ok end
    ]

    defaults
    |> Keyword.merge(overrides)
    |> Context.new()
  end

  defp topology(path) do
    header = path |> File.stream!() |> Enum.at(0) |> Jason.decode!()
    Map.take(header, ["parentId", "rootSessionId", "agentDepth"])
  end

  defp prepare_agent_environment do
    tmp = temp_dir()
    agents_dir = Path.join(tmp, "agents")
    sessions_root = Path.join(tmp, "sessions")
    File.mkdir_p!(agents_dir)
    File.write!(Path.join(agents_dir, "review.md"), "You are a focused reviewer.")

    replace_env(:agents_dir, agents_dir)
    replace_env(:sessions_root, sessions_root)

    {tmp, sessions_root}
  end

  defp spawn_call(context) do
    owner = self()

    start_supervised!(
      {Task,
       fn ->
         result =
           SpawnAgent.run(%{"agent" => "review", "task" => "Block until stopped."}, context)

         send(owner, {:spawn_agent_result, self(), result})
       end},
      id: {:spawn_agent_caller, make_ref()}
    )
  end

  defp assert_synchronized_children(root_id, expected) do
    _state = :sys.get_state(Children)
    assert Children.count(root_id) == expected
  end

  defp persisted_child_ids do
    Application.fetch_env!(:catalyst, :sessions_root)
    |> Path.join("**/*.jsonl")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> File.stream!()
      |> Enum.at(0)
      |> Jason.decode!()
      |> Map.fetch!("id")
    end)
  end

  defp temp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "catalyst_spawn_agent_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp replace_env(key, value) do
    previous = Application.fetch_env(:catalyst, key)
    Application.put_env(:catalyst, key, value)

    on_exit(fn ->
      case previous do
        {:ok, previous_value} -> Application.put_env(:catalyst, key, previous_value)
        :error -> Application.delete_env(:catalyst, key)
      end
    end)
  end
end
