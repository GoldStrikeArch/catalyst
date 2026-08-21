defmodule Catalyst.Runtime.LeasesTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [wait_until: 1]

  alias Catalyst.Runtime.{GenerationId, Leases}

  setup do
    :ok = Leases.revoke_all()
    on_exit(&Leases.revoke_all/0)
    :ok
  end

  test "acquires, lists, counts, and idempotently releases leases" do
    generation = generation("a")

    assert {:ok, lease} = Leases.acquire(generation, self(), :run)
    assert Leases.list() == [lease]
    assert Leases.count(generation) == 1

    assert :ok = Leases.release(lease)
    assert :ok = Leases.release(lease)
    assert Leases.list() == []
    assert Leases.count(generation) == 0
  end

  test "owner exit automatically releases all of its leases" do
    generation = generation("b")
    owner = start_supervised!({Agent, fn -> :lease_owner end})

    assert {:ok, _first} = Leases.acquire(generation, owner, :run)
    assert {:ok, _second} = Leases.acquire(generation, owner, :turn)
    assert Leases.count(generation) == 2

    Agent.stop(owner)
    wait_until(fn -> Leases.count(generation) == 0 end)

    assert Leases.list() == []
  end

  test "rejects an owner that is no longer alive" do
    owner = start_supervised!({Agent, fn -> :stopped_owner end})
    monitor = Process.monitor(owner)
    Agent.stop(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

    assert {:error, :lease_owner_not_alive} =
             Leases.acquire(generation("c"), owner, :run)
  end

  test "release remains harmless while the lease server name is unavailable" do
    assert {:ok, lease} = Leases.acquire(generation("d"), self(), :run)
    server = Process.whereis(Leases)
    assert Process.unregister(Leases)

    try do
      assert :ok = Leases.release(lease)
    after
      assert Process.register(server, Leases)
    end

    assert :ok = Leases.release(lease)
    assert Leases.list() == []
  end

  defp generation(character),
    do: GenerationId.candidate(String.duplicate(character, 64))
end
