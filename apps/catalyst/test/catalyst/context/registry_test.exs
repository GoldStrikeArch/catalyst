defmodule Catalyst.Context.RegistryTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.Context.Registry
  alias Catalyst.Model

  defmodule Policy do
    @behaviour Catalyst.Context.Policy

    @impl true
    def threshold(_model, _context), do: :none

    @impl true
    def compact(_messages, _context), do: {:error, :disabled}
  end

  setup do
    previous_policy = Application.fetch_env(:catalyst, :context_policy)
    previous_thresholds = Application.fetch_env(:catalyst, :context_thresholds)

    Catalyst.Runtime.Registry.purge_owner(:host)
    Catalyst.Runtime.Registry.purge_owner("registry-test-a")
    Catalyst.Runtime.Registry.purge_owner("registry-test-b")
    Application.delete_env(:catalyst, :context_policy)
    Application.delete_env(:catalyst, :context_thresholds)

    on_exit(fn ->
      Catalyst.Runtime.Registry.purge_owner(:host)
      Catalyst.Runtime.Registry.purge_owner("registry-test-a")
      Catalyst.Runtime.Registry.purge_owner("registry-test-b")
      restore_env(:context_policy, previous_policy)
      restore_env(:context_thresholds, previous_thresholds)
    end)

    :ok
  end

  test "threshold precedence is runtime id, api, default, then live application config" do
    model = %Model{id: "model-id", api: "model-api"}

    Application.put_env(:catalyst, :context_thresholds, %{
      "model-id" => 11,
      "model-api" => 12,
      default: 13
    })

    assert {:ok, 11, {:application, :context_thresholds, "model-id"}} =
             Registry.threshold(model)

    assert :ok = Registry.register_threshold(:default, 30, owner: "registry-test-a")

    assert {:ok, 30, {:extension, "registry-test-a", {:threshold, :default}}} =
             Registry.threshold(model)

    assert :ok = Registry.register_threshold("model-api", 20, owner: "registry-test-a")

    assert {:ok, 20, {:extension, "registry-test-a", {:threshold, "model-api"}}} =
             Registry.threshold(model)

    assert :ok = Registry.register_threshold("model-id", :none, owner: "registry-test-a")

    assert {:ok, :none, {:extension, "registry-test-a", {:threshold, "model-id"}}} =
             Registry.threshold(model)

    Catalyst.Runtime.Registry.purge_owner("registry-test-a")

    Application.put_env(:catalyst, :context_thresholds, %{"model-api" => 12, default: 13})

    assert {:ok, 12, {:application, :context_thresholds, "model-api"}} =
             Registry.threshold(model)
  end

  test "policy configuration stays live and runtime ownership collisions are explicit" do
    Application.put_env(:catalyst, :context_policy, Policy)
    assert {:ok, Policy, {:application, :context_policy}} = Registry.policy()

    Application.delete_env(:catalyst, :context_policy)
    assert {:ok, Catalyst.Context.Window, :builtin} = Registry.policy()

    assert :ok = Registry.register_policy(Policy, owner: "registry-test-a")
    assert {:ok, Policy, {:extension, "registry-test-a", {:policy, :default}}} = Registry.policy()

    assert {:error,
            {:owner_collision, :context_policy, nil, "registry-test-a", "registry-test-b"}} =
             Registry.register_policy(Policy, owner: "registry-test-b")

    assert :ok = Registry.register_threshold("model", 100, owner: "registry-test-a")

    assert {:error,
            {:owner_collision, :context_threshold, "model", "registry-test-a", "registry-test-b"}} =
             Registry.register_threshold("model", 200, owner: "registry-test-b")
  end

  test "invalid registrations and live configuration return tagged errors" do
    assert {:error, {:invalid_registration, {:threshold, "model"}, 1.5}} =
             Registry.register_threshold("model", 1.5)

    assert {:error, {:invalid_registration, {:threshold, ""}, 10}} =
             Registry.register_threshold("", 10)

    Application.put_env(:catalyst, :context_thresholds, %{"model" => 0})

    assert {:error, {:invalid_configuration, :context_thresholds, {"model", 0}}} =
             Registry.threshold(%Model{id: "model", api: "api"})
  end
end
