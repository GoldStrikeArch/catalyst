defmodule Catalyst.Workflow.RegistryTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.Runtime.Registry, as: RuntimeRegistry
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
    previous = %{
      workflows: Application.fetch_env(:catalyst, :workflows),
      agent_loop: Application.fetch_env(:catalyst, :agent_loop)
    }

    Application.delete_env(:catalyst, :workflows)
    Application.delete_env(:catalyst, :agent_loop)

    owner = "workflow_registry_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Catalyst.Runtime.Registry.purge_owner(owner)
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

  test "runtime registration is owner-aware and owner purge reveals fallbacks", %{owner: owner} do
    assert :ok = Registry.register_workflow("a-review", WorkflowB, owner: owner)
    assert :ok = Registry.register_workflow(:default, WorkflowA, owner: owner)

    assert {:ok, WorkflowB} = Registry.fetch("a-review")
    assert {:ok, WorkflowB, ^owner} = RuntimeRegistry.fetch(:workflow, "a-review")

    assert :ok = Catalyst.Runtime.Registry.purge_owner(owner)
    refute Enum.any?(RuntimeRegistry.list(:workflow), &(&1.owner == owner))
    assert {:error, {:unknown_workflow, "a-review"}} = Registry.fetch("a-review")
  end

  test "an owner may refresh its key but another owner and the host cannot replace it", %{
    owner: owner
  } do
    assert :ok = Registry.register_workflow("review", WorkflowA, owner: owner)
    assert :ok = Registry.register_workflow("review", WorkflowB, owner: owner)
    assert {:ok, WorkflowB} = Registry.fetch("review")

    assert {:error, {:owner_collision, :workflow, "review", ^owner, "other"}} =
             Registry.register_workflow("review", WorkflowA, owner: "other")

    assert {:error, {:owner_collision, :workflow, "review", ^owner, :host}} =
             Registry.register_workflow("review", WorkflowA)

    assert :ok = Catalyst.Runtime.Registry.purge_owner("other")
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

    refute Enum.any?(RuntimeRegistry.list(:workflow), &(&1.owner == owner))
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

  test "list/0 composes runtime, application, and built-in layers into picker rows", %{
    owner: owner
  } do
    assert %{name: :default, module: Catalyst.Agent.Loop, source: :builtin} =
             Enum.find(Registry.list(), &(&1.name == :default))

    Application.put_env(:catalyst, :workflows, %{
      "zeta" => WorkflowA,
      "review" => WorkflowA,
      default: WorkflowB
    })

    assert :ok = Registry.register_workflow("review", WorkflowB, owner: owner)
    assert :ok = Registry.register_workflow("alpha", WorkflowA, owner: owner)

    assert Registry.list()
           |> Enum.filter(&(&1.name in [:default, "alpha", "review", "zeta"])) == [
             %{
               name: :default,
               module: WorkflowB,
               source: {:application, {:workflows, :default}}
             },
             %{name: "alpha", module: WorkflowA, source: {:runtime, owner, {:workflow, "alpha"}}},
             %{
               name: "review",
               module: WorkflowB,
               source: {:runtime, owner, {:workflow, "review"}}
             },
             %{name: "zeta", module: WorkflowA, source: {:application, {:workflows, "zeta"}}}
           ]

    # A runtime default outranks the application default in the same row.
    assert :ok = Registry.register_workflow(:default, WorkflowA, owner: owner)

    assert %{name: :default, module: WorkflowA, source: {:runtime, ^owner, {:workflow, :default}}} =
             hd(Registry.list())
  end

  test "list/0 omits invalid rows instead of raising", %{owner: owner} do
    Application.put_env(:catalyst, :workflows, %{
      "review" => NotAWorkflow,
      default: NotAWorkflow
    })

    assert :ok = Registry.register_workflow("valid", WorkflowA, owner: owner)

    # The misconfigured app names and default are skipped; resolve/1 still
    # reports them as tagged errors when explicitly selected.
    assert Registry.list()
           |> Enum.filter(&(&1.name in [:default, "review", "valid"])) == [
             %{name: "valid", module: WorkflowA, source: {:runtime, owner, {:workflow, "valid"}}}
           ]

    assert {:error, {:invalid_configuration, {:workflows, "review"}, NotAWorkflow}} =
             Registry.resolve(workflow: "review")

    # A malformed :workflows value degrades list/0 to the valid layers only.
    Application.put_env(:catalyst, :workflows, :malformed)

    assert Registry.list()
           |> Enum.filter(&(&1.name in [:default, "review", "valid"])) == [
             %{name: "valid", module: WorkflowA, source: {:runtime, owner, {:workflow, "valid"}}}
           ]
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

    with_runtime_absent(fn ->
      assert RuntimeRegistry.list(:workflow) == []
      assert {:ok, WorkflowA} = Registry.fetch("review")
      assert {:ok, %{module: WorkflowB}} = Registry.resolve([])
      assert catch_exit(Catalyst.Runtime.Registry.purge_owner(owner))
    end)
  end

  defp with_runtime_absent(fun) do
    runtime = Process.whereis(RuntimeRegistry)
    supervisor = parent_supervisor(runtime)
    ref = Process.monitor(runtime)
    :ok = :sys.suspend(supervisor)

    try do
      Process.exit(runtime, :kill)
      assert_receive {:DOWN, ^ref, :process, ^runtime, :killed}
      assert Process.whereis(RuntimeRegistry) == nil
      fun.()
    after
      :ok = :sys.resume(supervisor)
      _replacement = wait_for_restart(RuntimeRegistry, runtime)
      assert :ok = Catalyst.Extensions.await_ready(5_000)
    end
  end

  defp parent_supervisor(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)

    dictionary
    |> Keyword.fetch!(:"$ancestors")
    |> List.first()
  end

  # Sanctioned poll: a supervisor restart re-registers the name with no
  # observable message to the test process.
  defp wait_for_restart(name, old_pid) do
    Catalyst.EnvCase.wait_until(
      fn ->
        case Process.whereis(name) do
          pid when is_pid(pid) and pid != old_pid -> {:ok, pid}
          _missing_or_old -> false
        end
      end,
      2_000,
      "#{inspect(name)} did not restart after the sabotaged write"
    )
  end
end
