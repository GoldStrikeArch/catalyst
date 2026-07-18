defmodule Catalyst.Context.ResourceCleanupTest do
  use ExUnit.Case, async: false

  alias Catalyst.Agent.Event
  alias Catalyst.Context.{Registry, Window}
  alias Catalyst.LLM.Registry, as: ProviderRegistry
  alias Catalyst.{Content, Message, Model}
  alias Catalyst.Session.{Manager, Server, Store}
  alias Catalyst.Test.{ReplacementCleanupProvider, SummaryCleanupProvider}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "catalyst_summary_cleanup_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    owner = "summary-cleanup-#{System.unique_integer([:positive])}"
    api = "summary-cleanup-#{System.unique_integer([:positive])}"
    previous_policy = runtime_policy()

    Registry.unregister_policy()
    Application.put_env(:catalyst, :summary_cleanup_test_pid, self())
    assert :ok = ProviderRegistry.register_provider(api, SummaryCleanupProvider, owner: owner)

    on_exit(fn ->
      Registry.unregister_policy()
      restore_runtime_policy(previous_policy)
      ProviderRegistry.unregister_owner(owner)
      Application.delete_env(:catalyst, :summary_cleanup_test_pid)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, owner: owner, api: api}
  end

  for mode <- [:success, :error] do
    @mode mode

    test "summary provider cleanup runs after #{@mode}", %{tmp: tmp, api: api} do
      {id, pid} = start_compacting_session(tmp, api, @mode)
      subscribe(id)

      assert :ok = Server.prompt(pid, "current request")
      assert_receive {:summary_started, _summary_pid, companion_id}, 1_000
      assert_receive {:summary_cleanup, SummaryCleanupProvider, ^companion_id}, 1_000
      assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
      assert_receive {:summary_cleanup, SummaryCleanupProvider, ^companion_id}, 1_000
      refute_receive {:summary_cleanup, SummaryCleanupProvider, ^companion_id}, 50
      _ = :sys.get_state(pid)

      refute Server.state(pid).running
      assert String.starts_with?(companion_id, "@compact:")
      refute companion_id == id
    end
  end

  test "summary timeout is cleaned after the brutally stopped summarizer", %{tmp: tmp, api: api} do
    previous_timeout = Application.fetch_env(:catalyst, :context_policy_timeout)
    Application.put_env(:catalyst, :context_policy_timeout, 200)
    on_exit(fn -> restore_env(:context_policy_timeout, previous_timeout) end)

    {id, pid} = start_compacting_session(tmp, api, :timeout)
    subscribe(id)

    assert :ok = Server.prompt(pid, "current request")
    assert_receive {:summary_started, summary_pid, companion_id}, 1_000
    summary_ref = Process.monitor(summary_pid)

    assert_receive {:DOWN, ^summary_ref, :process, ^summary_pid, :killed}, 1_000

    assert_receive {:agent_event, ^id,
                    %Event.ContextCompacted{summary: nil, replacement: [current]}},
                   1_000

    assert Content.text_of(current.content) == "current request"
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert_receive {:summary_cleanup, SummaryCleanupProvider, ^companion_id}, 1_000
    refute_receive {:summary_cleanup, SummaryCleanupProvider, ^companion_id}, 50

    snapshot = Server.state(pid)
    assert snapshot.error_message == nil

    assert Enum.map(snapshot.messages, &Content.text_of(&1.content)) == [
             "current request",
             "ordinary answer"
           ]

    assert Enum.map(Store.load(snapshot.store_path), &Content.text_of(&1.content)) == [
             "current request",
             "ordinary answer"
           ]

    persisted = File.read!(snapshot.store_path)
    assert persisted =~ ~s("type":"compaction")
    refute persisted =~ "context_status"
  end

  test "abort, reset, and termination clean blocked summary resources", %{tmp: tmp, api: api} do
    for action <- [:abort, :reset, :terminate] do
      {id, pid} = start_compacting_session(tmp, api, :block)
      subscribe(id)

      assert :ok = Server.prompt(pid, "current request")
      assert_receive {:summary_started, summary_pid, companion_id}, 1_000
      assert_run_resource(pid, SummaryCleanupProvider, companion_id)

      summary_ref = Process.monitor(summary_pid)
      session_ref = Process.monitor(pid)

      case action do
        :abort -> Server.abort(pid)
        :reset -> Server.reset(pid)
        :terminate -> assert :ok = Manager.stop(id)
      end

      assert_receive {:DOWN, ^summary_ref, :process, ^summary_pid, :killed}, 1_000
      assert_receive {:summary_cleanup, SummaryCleanupProvider, ^companion_id}, 1_000

      case action do
        :terminate ->
          assert_receive {:DOWN, ^session_ref, :process, ^pid, _reason}, 1_000

        _other ->
          assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
          Process.demonitor(session_ref, [:flush])
      end

      refute_receive {:summary_cleanup, SummaryCleanupProvider, ^companion_id}, 50
    end
  end

  test "cleanup uses the provider module resolved before a registry replacement", %{
    tmp: tmp,
    api: api,
    owner: owner
  } do
    {id, pid} = start_compacting_session(tmp, api, :block)
    subscribe(id)

    assert :ok = Server.prompt(pid, "current request")
    assert_receive {:summary_started, _summary_pid, companion_id}, 1_000
    assert_run_resource(pid, SummaryCleanupProvider, companion_id)

    assert :ok = ProviderRegistry.register_provider(api, ReplacementCleanupProvider, owner: owner)
    Server.abort(pid)

    assert_receive {:summary_cleanup, SummaryCleanupProvider, ^companion_id}, 1_000
    refute_receive {:summary_cleanup, ReplacementCleanupProvider, ^companion_id}, 100
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    refute_receive {:summary_cleanup, SummaryCleanupProvider, ^companion_id}, 50
  end

  test "stale resource registration is rejected without cleaning", %{tmp: tmp, api: api} do
    {_id, pid} = start_compacting_session(tmp, api, :success)
    companion_id = Window.companion_id("stale-resource")

    assert {:error, :stale_run} =
             GenServer.call(
               pid,
               {:register_run_resource, make_ref(),
                %{provider: SummaryCleanupProvider, session_id: companion_id}}
             )

    refute_receive {:summary_cleanup, SummaryCleanupProvider, ^companion_id}, 100
  end

  test "stale durable-event persistence is rejected", %{tmp: tmp, api: api} do
    {_id, pid} = start_compacting_session(tmp, api, :success)

    event = %Event.ContextCompacted{
      replacement: [Message.user("compacted")],
      summary: nil,
      replaced_count: 1,
      tokens_before: 2,
      tokens_after: 1,
      policy: :test
    }

    assert {:error, :stale_run} = GenServer.call(pid, {:persist_run_event, make_ref(), event})
  end

  defp start_compacting_session(tmp, api, mode) do
    id = "summary-cleanup-session-#{System.unique_integer([:positive, :monotonic])}"
    store = Store.new(tmp, id: id)
    Store.append_message(store, Message.user(String.duplicate("old history ", 100)))

    {:ok, %{pid: pid}} =
      Manager.start_session(
        id: id,
        cwd: tmp,
        system_prompt: "system",
        provider: api,
        model: %Model{
          id: "summary-model",
          api: api,
          provider: "summary-cleanup",
          context_window: 1_000
        },
        tools: [],
        opts: [context_threshold: 100, summary_cleanup_mode: mode]
      )

    on_exit(fn ->
      Manager.stop(id)
      File.rm(store.path)
      File.rmdir(Path.dirname(store.path))
    end)

    {id, pid}
  end

  defp subscribe(id), do: Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

  defp assert_run_resource(pid, provider, session_id) do
    resources = :sys.get_state(pid).run_resources

    assert Enum.any?(resources, fn resource ->
             resource.provider == provider and resource.session_id == session_id
           end)
  end

  defp runtime_policy do
    Enum.find(Registry.runtime_entries(), &(&1.key == {:policy, :default}))
  end

  defp restore_runtime_policy(nil), do: :ok

  defp restore_runtime_policy(entry) do
    Registry.register_policy(entry.value, owner: entry.owner)
  end

  defp restore_env(key, :error), do: Application.delete_env(:catalyst, key)
  defp restore_env(key, {:ok, value}), do: Application.put_env(:catalyst, key, value)
end
