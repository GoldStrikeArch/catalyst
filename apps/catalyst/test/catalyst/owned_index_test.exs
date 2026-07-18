defmodule Catalyst.OwnedIndexTest do
  use ExUnit.Case, async: true

  alias Catalyst.OwnedIndex

  test "claims, replaces for the same owner, and rejects collisions" do
    assert {:ok, index} = OwnedIndex.claim(OwnedIndex.new(), :key, :one)
    assert {:ok, ^index} = OwnedIndex.claim(index, :key, :one)
    assert {:error, :one} = OwnedIndex.claim(index, :key, :two)
    assert OwnedIndex.owner(index, :key) == :one
    assert OwnedIndex.keys(index, :one) == MapSet.new([:key])
  end

  test "release and owner release keep both directions consistent" do
    {:ok, index} = OwnedIndex.claim(OwnedIndex.new(), :first, :owner)
    {:ok, index} = OwnedIndex.claim(index, :second, :owner)
    index = OwnedIndex.release(index, :first)

    assert OwnedIndex.owner(index, :first) == nil
    assert OwnedIndex.keys(index, :owner) == MapSet.new([:second])

    assert {released, index} = OwnedIndex.release_owner(index, :owner)
    assert released == MapSet.new([:second])
    assert index == OwnedIndex.new()
  end

  test "untracked owners still participate in collision checks" do
    assert {:ok, index} =
             OwnedIndex.claim(OwnedIndex.new(), :host_key, :host, track_owner: false)

    assert OwnedIndex.owner(index, :host_key) == :host
    assert OwnedIndex.keys(index, :host) == MapSet.new()
    assert {released, ^index} = OwnedIndex.release_owner(index, :host)
    assert released == MapSet.new()
    assert {:error, :host} = OwnedIndex.claim(index, :host_key, :extension)
  end

  test "nil is a real owner for collision checks and cleanup" do
    assert {:ok, index} = OwnedIndex.claim(OwnedIndex.new(), :nullable, nil)
    assert {:ok, nil} = OwnedIndex.fetch_owner(index, :nullable)
    assert {:error, nil} = OwnedIndex.claim(index, :nullable, :other)
    assert OwnedIndex.keys(index, nil) == MapSet.new([:nullable])

    assert {released_keys, released} = OwnedIndex.release_owner(index, nil)
    assert released_keys == MapSet.new([:nullable])
    assert released == OwnedIndex.new()

    assert {:ok, index} = OwnedIndex.claim(OwnedIndex.new(), :nullable, nil)
    assert OwnedIndex.release(index, :nullable) == OwnedIndex.new()
  end
end
