defmodule Catalyst.Workflow.RegistryTest do
  use ExUnit.Case, async: false

  alias Catalyst.Workflow.Registry

  defmodule WorkflowA do
    @behaviour Catalyst.Workflow

    @impl true
    def run(_prompts, context, _config, _emit), do: {:ok, [], context}
  end

  defmodule WorkflowB do
    @behaviour Catalyst.Workflow

    @impl true
    def run(_prompts, context, _config, _emit), do: {:ok, [], context}

    @impl true
    def describe, do: %{name: "workflow-b"}
  end

  defmodule NotAWorkflow do
    def nope, do: :ok
  end

  setup do
    ensure_registry_started()

    previous = %{
      workflows: Application.fetch_env(:catalyst, :workflows),
      agent_loop: Application.fetch_env(:catalyst, :agent_loop)
    }

    Application.delete_env(:catalyst, :workflows)
    Application.delete_env(:catalyst, :agent_loop)

    owner = "workflow_registry_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if Process.whereis(Registry) do
        Registry.unregister_owner(owner)
      end

      restore_env(:workflows, previous.workflows)
      restore_env(:agent_loop, previous.agent_loop)
    end)

    {:ok, owner: owner}
  end

  test "workflow behaviour accepts describe/0 as an optional callback" do
    assert function_exported?(WorkflowA, :run, 4)
    refute function_exported?(WorkflowA, :describe, 0)
    assert WorkflowB.describe() == %{name: "workflow-b"}
  end

  test "runtime registration is owner-aware and runtime_entries are stable", %{owner: owner} do
    assert :ok = Registry.register_workflow("z-review", WorkflowA, owner: owner)
    assert :ok = Registry.register_workflow("a-review", WorkflowB, owner: owner)
    assert :ok = Registry.register_workflow(:default, WorkflowA, owner: owner)

    assert {:ok, WorkflowB} = Registry.fetch("a-review")

    assert Registry.runtime_entries() == [
             %{key: {:workflow, :default}, value: WorkflowA, owner: owner},
             %{key: {:workflow, "a-review"}, value: WorkflowB, owner: owner},
             %{key: {:workflow, "z-review"}, value: WorkflowA, owner: owner}
           ]

    assert :ok = Registry.unregister_owner(owner)
    assert Registry.runtime_entries() == []
    assert {:error, {:unknown_workflow, "a-review"}} = Registry.fetch("a-review")
  end

  test "an owner may refresh its key but another owner and the host cannot replace it", %{
    owner: owner
  } do
    assert :ok = Registry.register_workflow("review", WorkflowA, owner: owner)
    assert :ok = Registry.register_workflow("review", WorkflowB, owner: owner)
    assert {:ok, WorkflowB} = Registry.fetch("review")

    assert {:error, {:workflow_owner_collision, "review", ^owner, "other"}} =
             Registry.register_workflow("review", WorkflowA, owner: "other")

    assert {:error, {:workflow_owner_collision, "review", ^owner, :host}} =
             Registry.register_workflow("review", WorkflowA)

    assert :ok = Registry.unregister_owner("other")
    assert {:ok, WorkflowB} = Registry.fetch("review")
  end

  test "malformed runtime writes are rejected before ETS mutation", %{owner: owner} do
    for {name, module} <- [
          {"", WorkflowA},
          {"   ", WorkflowA},
          {:named_atom, WorkflowA},
          {"review", NotAWorkflow},
          {"review", :not_loaded_workflow_module}
        ] do
      assert {:error, {:invalid_registration, {:workflow, ^name}, ^module}} =
               Registry.register_workflow(name, module, owner: owner)
    end

    assert Registry.runtime_entries() == []
  end

  test "application workflow values are live and deleting them reveals lower layers" do
    Application.put_env(:catalyst, :workflows, %{
      "review" => WorkflowA,
      default: WorkflowB
    })

    assert {:ok, WorkflowA} = Registry.fetch("review")

    assert {:ok,
            %{name: :default, module: WorkflowB, source: {:application, {:workflows, :default}}}} =
             Registry.resolve([])

    Application.put_env(:catalyst, :workflows, %{default: WorkflowA})
    assert {:ok, %{module: WorkflowA}} = Registry.resolve([])

    Application.delete_env(:catalyst, :workflows)
    Application.put_env(:catalyst, :agent_loop, WorkflowB)

    assert {:ok, %{name: :default, module: WorkflowB, source: {:application, :agent_loop}}} =
             Registry.resolve([])

    Application.delete_env(:catalyst, :agent_loop)

    assert {:ok, %{name: :default, module: Catalyst.Agent.Loop, source: :builtin}} =
             Registry.resolve([])
  end

  test "full selection precedence is deterministic", %{owner: owner} do
    Application.put_env(:catalyst, :workflows, %{
      "review" => WorkflowA,
      default: WorkflowA
    })

    Application.put_env(:catalyst, :agent_loop, WorkflowA)
    assert :ok = Registry.register_workflow("review", WorkflowB, owner: owner)
    assert :ok = Registry.register_workflow(:default, WorkflowB, owner: owner)

    assert {:ok, %{name: :loop, module: WorkflowA, source: {:session, :loop}}} =
             Registry.resolve(loop: WorkflowA, workflow: "review")

    assert {:ok,
            %{
              name: "review",
              module: WorkflowB,
              source: {:runtime, ^owner, {:workflow, "review"}}
            }} = Registry.resolve(workflow: "review")

    assert :ok = Registry.unregister_workflow("review")

    assert {:ok,
            %{
              name: "review",
              module: WorkflowA,
              source: {:application, {:workflows, "review"}}
            }} = Registry.resolve(workflow: "review")

    assert {:ok,
            %{
              name: :default,
              module: WorkflowB,
              source: {:runtime, ^owner, {:workflow, :default}}
            }} = Registry.resolve([])

    assert :ok = Registry.unregister_workflow(:default)
    assert {:ok, %{name: :default, module: WorkflowA}} = Registry.resolve([])
  end

  test "an explicit unknown name and malformed selected configuration are tagged errors" do
    Application.put_env(:catalyst, :workflows, %{default: WorkflowA})

    assert {:error, {:unknown_workflow, "missing"}} =
             Registry.resolve(workflow: "missing")

    assert {:error, {:invalid_configuration, {:option, :workflow}, "  "}} =
             Registry.resolve(workflow: "  ")

    assert {:error, {:invalid_configuration, {:option, :loop}, NotAWorkflow}} =
             Registry.resolve(loop: NotAWorkflow)

    Application.put_env(:catalyst, :workflows, %{"review" => NotAWorkflow})

    assert {:error, {:invalid_configuration, {:workflows, "review"}, NotAWorkflow}} =
             Registry.resolve(workflow: "review")

    Application.put_env(:catalyst, :workflows, :malformed)
    assert {:error, {:invalid_configuration, :workflows, :malformed}} = Registry.resolve([])

    Application.delete_env(:catalyst, :workflows)
    Application.put_env(:catalyst, :agent_loop, NotAWorkflow)

    assert {:error, {:invalid_configuration, :agent_loop, NotAWorkflow}} =
             Registry.resolve([])
  end

  test "dropping a runtime key reveals the current application value", %{owner: owner} do
    Application.put_env(:catalyst, :workflows, %{"review" => WorkflowA})
    assert :ok = Registry.register_workflow("review", WorkflowB, owner: owner)
    assert {:ok, WorkflowB} = Registry.fetch("review")

    Application.put_env(:catalyst, :workflows, %{"review" => WorkflowB})
    assert :ok = Registry.unregister_workflow("review")
    assert {:ok, WorkflowB} = Registry.fetch("review")

    Application.put_env(:catalyst, :workflows, %{"review" => WorkflowA})
    assert {:ok, WorkflowA} = Registry.fetch("review")
  end

  test "reads fall back cleanly while the runtime ETS table is absent", %{owner: owner} do
    Application.put_env(:catalyst, :workflows, %{
      "review" => WorkflowA,
      default: WorkflowB
    })

    assert true = :ets.delete(Registry.table())
    assert Registry.runtime_entries() == []
    assert {:ok, WorkflowA} = Registry.fetch("review")
    assert {:ok, %{module: WorkflowB}} = Registry.resolve([])

    # Any subsequent write-side call recreates the owner table. This keeps the
    # shared test VM healthy without changing the missing-table read contract.
    assert :ok = Registry.unregister_owner(owner)
    assert is_reference(:ets.whereis(Registry.table()))
  end

  defp ensure_registry_started do
    case Process.whereis(Registry) do
      nil -> start_supervised!(Registry)
      _pid -> :ok
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:catalyst, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:catalyst, key)
end
