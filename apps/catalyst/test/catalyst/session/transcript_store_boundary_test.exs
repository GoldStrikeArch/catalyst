defmodule Catalyst.Session.TranscriptStoreBoundaryTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [wait_until: 1]

  alias Catalyst.Contracts.TranscriptStore.V1
  alias Catalyst.Extension.Manifest
  alias Catalyst.Runtime.{GenerationStore, Generations, TranscriptStore}
  alias Catalyst.Session.{Manager, Server, Store}
  alias Catalyst.{Content, Message}

  setup do
    :ok = Generations.clear()
    :persistent_term.put({Catalyst.Test.TranscriptStoreA, :test_pid}, self())
    :persistent_term.put({Catalyst.Test.TranscriptStoreB, :test_pid}, self())

    tmp =
      Path.join(
        System.tmp_dir!(),
        "transcript_store_boundary_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    on_exit(fn ->
      :persistent_term.erase({Catalyst.Test.TranscriptStoreA, :test_pid})
      :persistent_term.erase({Catalyst.Test.TranscriptStoreB, :test_pid})
      Generations.clear()
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "old sessions keep their store while new sessions use the replacement", %{tmp: tmp} do
    first_manifest = manifest("test.transcript-store-a", Catalyst.Test.TranscriptStoreA)

    assert {:ok, first_generation} =
             Generations.install("transcript_store_source", [first_manifest])

    first_id = "transcript-store-a-#{System.unique_integer([:positive])}"
    assert {:ok, first} = Manager.start_session(id: first_id, cwd: tmp)

    second_manifest = manifest("test.transcript-store-b", Catalyst.Test.TranscriptStoreB)

    assert {:ok, second_generation} =
             Generations.install("transcript_store_source", [second_manifest])

    second_id = "transcript-store-b-#{System.unique_integer([:positive])}"
    assert {:ok, second} = Manager.start_session(id: second_id, cwd: tmp)

    on_exit(fn ->
      Manager.stop(first_id)
      Manager.stop(second_id)
    end)

    first_message = assistant("first backend")
    second_message = assistant("second backend")

    assert :ok = Server.append_recovered(first.pid, first_message)
    assert_receive {:transcript_store, :a, :append_message}

    assert :ok = Server.append_recovered(second.pid, second_message)
    assert_receive {:transcript_store, :b, :append_message}

    first_snapshot = Server.state(first.pid)
    second_snapshot = Server.state(second.pid)

    assert first_snapshot.transcript_store.owner == first_manifest.id
    assert second_snapshot.transcript_store.owner == second_manifest.id
    assert first_snapshot.transcript_store.handle_version == 1
    assert second_snapshot.transcript_store.handle_version == 1

    assert [persisted_first] = Store.load(first_snapshot.store_path)
    assert [persisted_second] = Store.load(second_snapshot.store_path)
    assert Content.text_of(persisted_first.content) == "first backend"
    assert Content.text_of(persisted_second.content) == "second backend"

    assert {:ok, %{status: :retiring}} = GenerationStore.fetch(first_generation.id)
    assert {:ok, %{status: :active}} = GenerationStore.fetch(second_generation.id)

    assert :ok = Manager.stop(first_id)

    wait_until(fn ->
      match?({:ok, %{status: :retired}}, GenerationStore.fetch(first_generation.id))
    end)

    assert :ok = Manager.stop(second_id)
  end

  defp manifest(id, implementation) do
    Manifest.new!(%{
      id: id,
      version: "1.0.0",
      services: [
        %{
          key: TranscriptStore.key(),
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
end
