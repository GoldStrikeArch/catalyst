defmodule CatalystWeb.Workbench.RenderTargetTest do
  use CatalystWeb.ConnCase, async: false

  alias CatalystWeb.UI.Registry
  alias CatalystWeb.Workbench
  alias CatalystWeb.Workbench.RenderTarget

  setup do
    owner = "render_target_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> Registry.unregister_owner(owner) end)
    %{owner: owner}
  end

  test "captures an immutable effective descriptor", %{owner: owner} do
    assert :ok =
             Registry.register_page("pinned-target", CatalystWeb.Test.WorkbenchTargetA,
               owner: owner
             )

    assert {:ok, handle} = Workbench.resolve_and_pin(%{}, self())
    assert {:ok, target} = RenderTarget.capture("pinned-target", handle)

    assert target.id == "pinned-target"
    assert target.module == CatalystWeb.Test.WorkbenchTargetA
    assert target.function == :render
    assert target.owner == owner
    assert target.snapshot_id == handle.resolution.snapshot_id

    assert :ok =
             Registry.register_page("pinned-target", CatalystWeb.Test.WorkbenchTargetB,
               owner: owner
             )

    assert target.module == CatalystWeb.Test.WorkbenchTargetA
    assert {:ok, replacement} = RenderTarget.capture("pinned-target", handle)
    assert replacement.module == CatalystWeb.Test.WorkbenchTargetB
  end

  test "fails closed for missing or non-renderable descriptors", %{owner: owner} do
    assert {:ok, handle} = Workbench.resolve_and_pin(%{}, self())

    assert {:error,
            {:workbench_render_target_unavailable, {CatalystWeb.Workbench.IDE, :render},
             :undefined}} =
             RenderTarget.capture({CatalystWeb.Workbench.IDE, :render}, handle)

    assert {:error, :workbench_render_target_not_registered} =
             RenderTarget.capture("missing-target", handle)

    assert :ok =
             Registry.register_page("not-renderable", CatalystWeb.Test.Workbench, owner: owner)

    assert {:error, {:workbench_render_target_unavailable, "not-renderable", :undefined}} =
             RenderTarget.capture("not-renderable", handle)
  end

  test "captures a callback on the exact built-in implementation" do
    assert {:ok, handle} =
             Workbench.resolve_and_pin(%{metadata: %{workbench_slot: "chat"}}, self())

    assert {:ok, target} =
             RenderTarget.capture({CatalystWeb.Workbench.Chat, :render}, handle)

    assert target.module == CatalystWeb.Workbench.Chat
    assert target.function == :render
    assert target.owner == :builtin
    assert target.generation == nil
    assert target.artifact == nil
  end
end
