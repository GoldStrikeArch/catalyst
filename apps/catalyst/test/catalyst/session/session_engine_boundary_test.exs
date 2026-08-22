defmodule Catalyst.Session.SessionEngineBoundaryTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [wait_until: 1]

  alias Catalyst.Contracts.SessionEngine.V1
  alias Catalyst.Extension.Manifest
  alias Catalyst.Runtime.{GenerationStore, Generations, SessionEngine}
  alias Catalyst.Session.{Manager, Server, Store}
  alias Catalyst.{Content, Message}

  setup do
    :ok = Generations.clear()

    tmp =
      Path.join(
        System.tmp_dir!(),
        "session_engine_boundary_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    on_exit(fn ->
      Generations.clear()
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "existing sessions keep their engine while new sessions use the replacement", %{tmp: tmp} do
    first_manifest = manifest("test.session-engine-a", Catalyst.Test.SessionEngineA)

    assert {:ok, first_generation} =
             Generations.install("session_engine_source", [first_manifest])

    first_id = "session-engine-a-#{System.unique_integer([:positive])}"
    assert {:ok, first} = Manager.start_session(id: first_id, cwd: tmp)

    second_manifest = manifest("test.session-engine-b", Catalyst.Test.SessionEngineB)

    assert {:ok, second_generation} =
             Generations.install("session_engine_source", [second_manifest])

    second_id = "session-engine-b-#{System.unique_integer([:positive])}"
    assert {:ok, second} = Manager.start_session(id: second_id, cwd: tmp)

    on_exit(fn ->
      Manager.stop(first_id)
      Manager.stop(second_id)
    end)

    message = %Message.Assistant{
      content: Content.text("unchanged persisted payload"),
      timestamp: Message.now()
    }

    assert :ok = Server.append_recovered(first.pid, message)
    assert :ok = Server.append_recovered(second.pid, message)

    first_snapshot = Server.state(first.pid)
    second_snapshot = Server.state(second.pid)

    assert first_snapshot.error_message == "session-engine-a"
    assert second_snapshot.error_message == "session-engine-b"
    assert first_snapshot.session_engine.owner == first_manifest.id
    assert second_snapshot.session_engine.owner == second_manifest.id
    assert [persisted_first] = Store.load(first_snapshot.store_path)
    assert [persisted_second] = Store.load(second_snapshot.store_path)
    assert Content.text_of(persisted_first.content) == "unchanged persisted payload"
    assert Content.text_of(persisted_second.content) == "unchanged persisted payload"
    assert persisted_first.error_message == nil
    assert persisted_second.error_message == nil

    assert {:ok, %{status: :retiring}} = GenerationStore.fetch(first_generation.id)
    assert {:ok, %{status: :active}} = GenerationStore.fetch(second_generation.id)

    assert :ok = Manager.stop(first_id)

    wait_until(fn ->
      match?({:ok, %{status: :retired}}, GenerationStore.fetch(first_generation.id))
    end)

    assert :ok = Manager.stop(second_id)
  end

  test "PubSub keeps broadcasting the raw agent event", %{tmp: tmp} do
    id = "session-engine-pubsub-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Manager.start_session(id: id, cwd: tmp)
    on_exit(fn -> Manager.stop(id) end)
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    message = %Message.Assistant{content: Content.text("raw event"), timestamp: Message.now()}
    assert :ok = Server.append_recovered(session.pid, message)

    assert_receive {:agent_event, ^id, %Catalyst.Agent.Event.MessageEnd{message: ^message}}
    assert :ok = Manager.stop(id)
  end

  test "a quiescent session handoffs state and its generation lease", %{tmp: tmp} do
    first_manifest = manifest("test.session-engine-a", Catalyst.Test.SessionEngineA)
    assert {:ok, first_generation} = Generations.install("handoff_source", [first_manifest])

    id = "session-engine-handoff-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Manager.start_session(id: id, cwd: tmp)
    on_exit(fn -> Manager.stop(id) end)

    first_message = assistant("before handoff")
    assert :ok = Server.append_recovered(session.pid, first_message)
    before = Server.state(session.pid)
    assert before.error_message == "session-engine-a"

    second_manifest = manifest("test.session-engine-b", Catalyst.Test.SessionEngineB)
    assert {:ok, second_generation} = Generations.install("handoff_source", [second_manifest])

    assert %{status: :retiring, lease_count: 1} = generation(first_generation.id)
    assert %{status: :active, lease_count: 0} = generation(second_generation.id)

    assert :ok = Server.handoff_session_engine(session.pid)
    after_handoff = Server.state(session.pid)

    assert after_handoff.session_engine.owner == second_manifest.id
    assert after_handoff.messages == before.messages
    assert after_handoff.error_message == before.error_message
    assert after_handoff.store_path == before.store_path
    assert length(Store.load(after_handoff.store_path)) == 1

    wait_until(fn -> generation(first_generation.id).status == :retired end)
    assert %{status: :retired, lease_count: 0} = generation(first_generation.id)
    assert %{status: :active, lease_count: 1} = generation(second_generation.id)

    assert :ok = Server.append_recovered(session.pid, assistant("after handoff"))
    assert Server.state(session.pid).error_message == "session-engine-b"
    assert length(Store.load(after_handoff.store_path)) == 2

    assert :ok = Manager.stop(id)
    wait_until(fn -> generation(second_generation.id).lease_count == 0 end)
  end

  test "handoff rejects an active run without acquiring the replacement lease", %{tmp: tmp} do
    first_manifest = manifest("test.session-engine-a", Catalyst.Test.SessionEngineA)
    assert {:ok, first_generation} = Generations.install("busy_handoff_source", [first_manifest])

    ref = make_ref()
    id = "session-engine-busy-handoff-#{System.unique_integer([:positive])}"

    assert {:ok, session} =
             Manager.start_session(
               id: id,
               cwd: tmp,
               opts: [
                 loop: Catalyst.Test.BlockingWorkflow,
                 blocking_test_pid: self(),
                 blocking_ref: ref
               ]
             )

    on_exit(fn -> Manager.stop(id) end)
    assert :ok = Server.prompt(session.pid, "hold")
    assert_receive {:blocking_workflow_started, ^ref, worker}, 1_000

    second_manifest = manifest("test.session-engine-b", Catalyst.Test.SessionEngineB)

    assert {:ok, second_generation} =
             Generations.install("busy_handoff_source", [second_manifest])

    assert {:error, :session_running} = Server.handoff_session_engine(session.pid)
    assert Server.state(session.pid).session_engine.owner == first_manifest.id
    assert %{status: :retiring, lease_count: 1} = generation(first_generation.id)
    assert %{status: :active, lease_count: 0} = generation(second_generation.id)

    send(worker, {:release_blocking_workflow, ref})
    wait_until(fn -> Server.state(session.pid).running == false end)
  end

  test "a rejected restore leaves state and the source lease untouched", %{tmp: tmp} do
    first_manifest = manifest("test.session-engine-a", Catalyst.Test.SessionEngineA)

    assert {:ok, first_generation} =
             Generations.install("failed_handoff_source", [first_manifest])

    id = "session-engine-failed-handoff-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Manager.start_session(id: id, cwd: tmp)
    on_exit(fn -> Manager.stop(id) end)

    assert :ok = Server.append_recovered(session.pid, assistant("preserved"))
    before = Server.state(session.pid)

    rejecting =
      manifest("test.session-engine-reject", Catalyst.Test.SessionEngineRejectRestore)

    assert {:ok, rejecting_generation} =
             Generations.install("failed_handoff_source", [rejecting])

    assert {:error, :restore_rejected} = Server.handoff_session_engine(session.pid)
    after_failure = Server.state(session.pid)

    assert after_failure.session_engine == before.session_engine
    assert after_failure.messages == before.messages
    assert after_failure.error_message == before.error_message
    assert %{status: :retiring, lease_count: 1} = generation(first_generation.id)
    assert %{status: :active, lease_count: 0} = generation(rejecting_generation.id)

    assert :ok = Server.append_recovered(session.pid, assistant("still source"))
    assert Server.state(session.pid).error_message == "session-engine-a"
  end

  defp manifest(id, implementation) do
    Manifest.new!(%{
      id: id,
      version: "1.0.0",
      services: [
        %{
          key: SessionEngine.key(),
          contract: V1.ref(),
          implementation: implementation,
          priority: 900,
          binding: {:pin, :session}
        }
      ]
    })
  end

  defp assistant(text) do
    %Message.Assistant{content: Content.text(text), timestamp: Message.now()}
  end

  defp generation(id), do: Enum.find(Generations.list(), &(&1.id == id))
end
