defmodule Catalyst.ResourcesTest do
  use ExUnit.Case, async: false

  alias Catalyst.Contracts.PermissionPolicy.V1
  alias Catalyst.ExtensionAPI
  alias Catalyst.Resources
  alias Catalyst.Runtime.{ExtensionPoints, PermissionPolicy}

  defmodule DenyPolicy do
    @behaviour Catalyst.Contracts.PermissionPolicy.V1

    @impl true
    def authorize(_action, _principal, _resource, _context), do: {:deny, :not_granted}
  end

  setup do
    owner = "resource_policy_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> ExtensionPoints.purge_owner(owner) end)
    {:ok, owner: owner}
  end

  test "runs an operation only after the effective policy allows it" do
    assert {:ok, :performed} =
             Resources.request(action(), principal(), resource(), %{}, fn -> :performed end)
  end

  test "a denial cannot perform the brokered operation", %{owner: owner} do
    test_pid = self()
    claim_policy(owner, DenyPolicy)

    assert {:error, {:denied, :not_granted}} =
             Resources.request(action(), principal(), resource(), %{}, fn ->
               send(test_pid, :performed)
             end)

    refute_received :performed
  end

  defp claim_policy(owner, module) do
    assert :ok =
             owner
             |> ExtensionAPI.new()
             |> ExtensionAPI.claim(PermissionPolicy.key(), module,
               contract: V1.ref(),
               priority: 900
             )
  end

  defp action, do: %{type: :test}
  defp principal, do: %{type: :agent}
  defp resource, do: %{type: :test_resource}
end
