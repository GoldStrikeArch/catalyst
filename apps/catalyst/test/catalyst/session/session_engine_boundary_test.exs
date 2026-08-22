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
end
