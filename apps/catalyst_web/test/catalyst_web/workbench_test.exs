defmodule CatalystWeb.WorkbenchTest do
  use ExUnit.Case, async: false

  alias Catalyst.Contracts.Workbench.V1
  alias Catalyst.ExtensionAPI
  alias Catalyst.Runtime.ExtensionPoints
  alias CatalystWeb.Workbench

  setup do
    owner = "workbench_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> ExtensionPoints.purge_owner(owner) end)
    {:ok, owner: owner}
  end

  test "the IDE is an ordinary mount-bound Runtime Graph claim" do
    assert {:ok, resolution} = Workbench.resolve()
    assert resolution.claim.owner == :builtin
    assert resolution.claim.implementation == CatalystWeb.Workbench.IDE
    assert resolution.claim.binding == {:pin, :mount}

    assert Enum.any?(Catalyst.Runtime.snapshot().claims, fn claim ->
             claim.key == Workbench.key() and claim.owner == :builtin
           end)
  end

  test "chat is an independent built-in workbench slot" do
    assert {:ok, resolution} =
             Workbench.resolve(%{metadata: %{workbench_slot: "chat"}})

    assert resolution.key == Workbench.key("chat")
    assert resolution.claim.owner == :builtin
    assert resolution.claim.implementation == CatalystWeb.Workbench.Chat
    assert resolution.claim.binding == {:pin, :mount}
  end

  test "a claimed workbench resolves through a process-owned handle", %{owner: owner} do
    assert :ok =
             ExtensionAPI.claim(
               ExtensionAPI.new(owner),
               Workbench.key(),
               CatalystWeb.Test.Workbench,
               contract: V1.ref(),
               priority: 900
             )

    assert {:ok, handle} = Workbench.resolve_and_pin(%{}, self())
    assert handle.owner == owner
    assert handle.binding == {:pin, :mount}
    assert handle.lease == nil
    assert :ok = Workbench.release(handle)
  end
end
