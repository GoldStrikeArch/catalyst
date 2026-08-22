defmodule Catalyst.Session.SessionFactoryBoundaryTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [wait_until: 1]

  alias Catalyst.Contracts.SessionFactory.V1
  alias Catalyst.Extension.Manifest
  alias Catalyst.Runtime.{Generations, Leases, SessionFactory}
  alias Catalyst.Session.{Manager, Server}

  setup do
    :ok = Generations.clear()
    :persistent_term.put({Catalyst.Test.SessionFactoryA, :test_pid}, self())
    :persistent_term.put({Catalyst.Test.SessionFactoryB, :test_pid}, self())

    tmp =
      Path.join(
        System.tmp_dir!(),
        "session_factory_boundary_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    on_exit(fn ->
      :persistent_term.erase({Catalyst.Test.SessionFactoryA, :test_pid})
      :persistent_term.erase({Catalyst.Test.SessionFactoryB, :test_pid})
      Generations.clear()
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "new sessions pin their selected factory and owner removal exposes the built-in", %{
    tmp: tmp
  } do
    first_manifest = manifest("test.session-factory-a", Catalyst.Test.SessionFactoryA)
    assert {:ok, first_generation} = Generations.install("factory_source", [first_manifest])

    first_id = "session-factory-a-#{System.unique_integer([:positive])}"
    assert {:ok, first} = Manager.start_session(id: first_id, cwd: tmp)
    assert_receive {:session_factory, :a}

    second_manifest = manifest("test.session-factory-b", Catalyst.Test.SessionFactoryB)
    assert {:ok, second_generation} = Generations.install("factory_source", [second_manifest])

    second_id = "session-factory-b-#{System.unique_integer([:positive])}"
    assert {:ok, second} = Manager.start_unique_session(id: second_id, cwd: tmp)
    assert_receive {:session_factory, :b}

    on_exit(fn ->
      Manager.stop(first_id)
      Manager.stop(second_id)
    end)

    assert Server.state(first.pid).session_factory.owner == first_manifest.id
    assert Server.state(second.pid).session_factory.owner == second_manifest.id
    assert lease_owner(first_generation.id) == first.pid
    assert lease_owner(second_generation.id) == second.pid

    assert :ok = Generations.remove_owner("factory_source")

    fallback_id = "session-factory-fallback-#{System.unique_integer([:positive])}"
    assert {:ok, fallback} = Manager.start_session(id: fallback_id, cwd: tmp)
    on_exit(fn -> Manager.stop(fallback_id) end)

    assert Server.state(fallback.pid).session_factory.owner == :builtin
    refute_receive {:session_factory, _factory}
    assert Server.state(first.pid).session_factory.owner == first_manifest.id
    assert Server.state(second.pid).session_factory.owner == second_manifest.id

    assert :ok = Manager.stop(first_id)
    wait_until(fn -> generation(first_generation.id).lease_count == 0 end)
    assert :ok = Manager.stop(second_id)
    wait_until(fn -> generation(second_generation.id).lease_count == 0 end)
  end

  test "a direct Server child start remains available without a managed factory handle", %{
    tmp: tmp
  } do
    id = "direct-session-server-#{System.unique_integer([:positive])}"
    pid = start_supervised!({Server, [id: id, cwd: tmp]})

    assert Server.state(pid).id == id
    assert Server.state(pid).session_factory == nil
  end

  defp manifest(id, implementation) do
    Manifest.new!(%{
      id: id,
      version: "1.0.0",
      services: [
        %{
          key: SessionFactory.key(),
          contract: V1.ref(),
          implementation: implementation,
          priority: 900,
          binding: {:pin, :session}
        }
      ]
    })
  end

  defp lease_owner(generation_id) do
    generation_id
    |> then(fn id -> Enum.find(Leases.list(), &(&1.generation == id)) end)
    |> Map.fetch!(:owner)
  end

  defp generation(id), do: Enum.find(Generations.list(), &(&1.id == id))
end
