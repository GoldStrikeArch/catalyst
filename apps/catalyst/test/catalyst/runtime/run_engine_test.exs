defmodule Catalyst.Runtime.RunEngineTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.Runtime.RunEngine
  alias Catalyst.ExtensionAPI
  alias Catalyst.Workflow.Registry

  defmodule RuntimeWorkflow do
    @behaviour Catalyst.Workflow

    @impl true
    def run(_prompts, context, _config, _emit), do: {:ok, [], context}
  end

  setup do
    previous_workflows = Application.fetch_env(:catalyst, :workflows)
    previous_loop = Application.fetch_env(:catalyst, :agent_loop)
    owner = "runtime_graph_run_engine_#{System.unique_integer([:positive])}"

    Application.delete_env(:catalyst, :workflows)
    Application.delete_env(:catalyst, :agent_loop)
    :ok = Registry.unregister_owner(owner)

    on_exit(fn ->
      :ok = Registry.unregister_owner(owner)
      restore_env(:workflows, previous_workflows)
      restore_env(:agent_loop, previous_loop)
    end)

    {:ok, owner: owner}
  end

  test "the built-in loop is an ordinary run-engine claim" do
    assert {:ok, %{selection: selection, resolution: resolution}} =
             RunEngine.resolve([], session_id: "session-1")

    assert selection == %{name: :default, module: Catalyst.Agent.Loop, source: :builtin}
    assert resolution.claim.owner == :builtin
    assert resolution.claim.implementation == Catalyst.Agent.Loop
    assert resolution.claim.binding == {:pin, :run}
    assert resolution.explanation.hidden == []

    assert RunEngine.metadata(resolution) == %{
             service: "agent.run_engine/default",
             contract: %{id: "catalyst.agent-run-engine", version: 1},
             snapshot_id: resolution.snapshot_id,
             owner: :builtin,
             scope: %{},
             binding: {:pin, :run},
             provenance: :builtin,
             implementation: Catalyst.Agent.Loop
           }
  end

  test "a runtime default claim hides the built-in fallback", %{owner: owner} do
    assert :ok = Registry.register_workflow(:default, RuntimeWorkflow, owner: owner)

    assert {:ok, %{selection: selection, resolution: resolution}} =
             RunEngine.resolve([], session_id: "session-1")

    assert selection.module == RuntimeWorkflow
    assert resolution.claim.owner == owner
    assert resolution.claim.provenance == {:runtime, owner, {:workflow, :default}}
    assert Enum.map(resolution.explanation.hidden, & &1.owner) == [:builtin]
  end

  test "a pinned handle invokes its exact local target", %{owner: owner} do
    assert :ok = Registry.register_workflow(:default, RuntimeWorkflow, owner: owner)
    assert {:ok, resolved} = RunEngine.resolve([], session_id: "session-1")
    assert {:ok, pinned} = RunEngine.pin(resolved)

    assert {:ok, [], %{value: 1}} =
             RunEngine.invoke(pinned.handle, [], %{value: 1}, %{}, fn _event -> :ok end)

    assert :ok = RunEngine.release(pinned)
  end

  test "the default explanation includes every valid lower workflow layer", %{owner: owner} do
    Application.put_env(:catalyst, :workflows, %{default: RuntimeWorkflow})
    Application.put_env(:catalyst, :agent_loop, Catalyst.Test.RunBoundaryWorkflow)
    assert :ok = Registry.register_workflow(:default, RuntimeWorkflow, owner: owner)

    assert {:ok, explanation} = RunEngine.explain([], session_id: "session-1")
    assert explanation.selected.owner == owner

    assert Enum.map(explanation.hidden, & &1.provenance) == [
             {:application, {:workflows, :default}},
             {:application, :agent_loop},
             :builtin
           ]
  end

  test "a direct loop is represented as a session-scoped direct slot" do
    assert {:ok, %{selection: selection, resolution: resolution}} =
             RunEngine.resolve([loop: RuntimeWorkflow], session_id: "session-1")

    assert selection.source == {:session, :loop}
    assert resolution.key.slot == "direct"
    assert resolution.claim.owner == {:session, "session-1"}
    assert resolution.claim.scope.constraints == %{session_id: "session-1"}
  end

  test "the named workflow \"default\" remains distinct from the runtime default", %{owner: owner} do
    api = ExtensionAPI.new(owner)

    assert :ok = ExtensionAPI.register_workflow(api, :default, RuntimeWorkflow)
    assert :ok = ExtensionAPI.register_workflow(api, "default", Catalyst.Agent.Loop)

    assert {:ok, %{name: :default, module: RuntimeWorkflow}} = Registry.resolve([])

    assert {:ok, %{name: "default", module: Catalyst.Agent.Loop}} =
             Registry.resolve(workflow: "default")

    assert RunEngine.key(:default).slot == "default"
    assert RunEngine.key("default").slot == "named:default"
  end

  test "invalid extension workflow names return tagged errors instead of raising", %{owner: owner} do
    assert {:error, {:invalid_workflow_name, ""}} =
             owner
             |> ExtensionAPI.new()
             |> ExtensionAPI.register_workflow("", RuntimeWorkflow)
  end

  test "invalid workflow options retain the legacy tagged error" do
    assert {:error, {:invalid_configuration, {:option, :workflow}, ""}} =
             RunEngine.resolve(workflow: "")
  end

  test "the direct service slot maps to the loop selection name" do
    assert {:ok, :loop} = RunEngine.workflow_name(RunEngine.key(:loop))
  end
end
