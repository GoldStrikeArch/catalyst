defmodule Catalyst.Runtime.RegistryTest do
  use ExUnit.Case, async: false

  alias Catalyst.Runtime.Registry

  setup do
    Registry.purge_owner(:host)
    Registry.purge_owner("runtime-a")
    Registry.purge_owner("runtime-b")

    on_exit(fn ->
      Registry.purge_owner(:host)
      Registry.purge_owner("runtime-a")
      Registry.purge_owner("runtime-b")
    end)
  end

  test "stores opaque contribution kinds in one owner-aware table" do
    assert :ok = Registry.put(:prompt, {:system, :default}, "first", owner: "runtime-a")
    assert :ok = Registry.put(:provider, "example", Example, owner: "runtime-b")

    assert {:ok, "first", "runtime-a"} =
             Registry.fetch(:prompt, {:system, :default})

    assert %{kind: :provider, key: "example", owner: "runtime-b", value: Example} in Registry.list(
             :provider
           )
  end

  test "same-owner refresh succeeds and cross-owner writes share one collision shape" do
    assert :ok = Registry.put(:workflow, :default, First, owner: "runtime-a")
    assert :ok = Registry.put(:workflow, :default, Second, owner: "runtime-a")

    assert {:error, {:owner_collision, :workflow, nil, "runtime-a", "runtime-b"}} =
             Registry.put(:workflow, :default, Third,
               owner: "runtime-b",
               collision_key: nil
             )

    assert {:ok, Second, "runtime-a"} = Registry.fetch(:workflow, :default)
  end

  test "owner purge crosses kinds without disturbing other owners" do
    assert :ok = Registry.put(:prompt, :one, 1, owner: "runtime-a")
    assert :ok = Registry.put(:hook, :two, 2, owner: "runtime-a")
    assert :ok = Registry.put(:page, :three, 3, owner: "runtime-b")

    assert :ok = Registry.purge_owner("runtime-a")
    assert :error = Registry.fetch(:prompt, :one)
    assert :error = Registry.fetch(:hook, :two)
    assert {:ok, 3, "runtime-b"} = Registry.fetch(:page, :three)
  end
end
