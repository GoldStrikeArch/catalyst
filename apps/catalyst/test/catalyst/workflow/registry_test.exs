defmodule Catalyst.Workflow.RegistryTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.Workflow.{Registry, Template}

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

  defmodule TemplateStore do
    def list do
      {:ok, Application.get_env(:catalyst, :workflow_registry_test_templates, [])}
    end

    def fetch(name) do
      case Enum.find(Application.get_env(:catalyst, :workflow_registry_test_templates, []), fn
             %Catalyst.Workflow.Template{id: ^name} -> true
             _template -> false
           end) do
        nil -> :error
        template -> {:ok, template}
      end
    end
  end

  setup do
    ensure_registry_started()

    previous = %{
      workflows: Application.fetch_env(:catalyst, :workflows),
      acp_agents: Application.fetch_env(:catalyst, :acp_agents),
      agent_loop: Application.fetch_env(:catalyst, :agent_loop),
      workflow_template_store: Application.fetch_env(:catalyst, :workflow_template_store),
      workflow_registry_test_templates:
        Application.fetch_env(:catalyst, :workflow_registry_test_templates)
    }

    Application.delete_env(:catalyst, :workflows)
    Application.delete_env(:catalyst, :acp_agents)
    Application.delete_env(:catalyst, :agent_loop)
    Application.put_env(:catalyst, :workflow_template_store, TemplateStore)
    Application.put_env(:catalyst, :workflow_registry_test_templates, [])

    owner = "workflow_registry_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if Process.whereis(Registry) do
        Registry.unregister_owner(owner)
      end

      restore_env(:workflows, previous.workflows)
      restore_env(:acp_agents, previous.acp_agents)
      restore_env(:agent_loop, previous.agent_loop)
      restore_env(:workflow_template_store, previous.workflow_template_store)

      restore_env(
        :workflow_registry_test_templates,
        previous.workflow_registry_test_templates
      )
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

    # Stable inspect-order, matching the prompt/context registries' convention.
    assert Registry.runtime_entries() == [
             %{key: {:workflow, "a-review"}, value: WorkflowB, owner: owner},
             %{key: {:workflow, "z-review"}, value: WorkflowA, owner: owner},
             %{key: {:workflow, :default}, value: WorkflowA, owner: owner}
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

    assert {:error, {:owner_collision, :workflow, "review", ^owner, "other"}} =
             Registry.register_workflow("review", WorkflowA, owner: "other")

    assert {:error, {:owner_collision, :workflow, "review", ^owner, :host}} =
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

  test "configured ACP agents are live generic workflow entries" do
    Application.put_env(:catalyst, :acp_agents, [
      %{
        "id" => "fixture",
        "name" => "Fixture",
        "command" => "fixture",
        "args" => [],
        "env" => %{}
      }
    ])

    assert {:ok,
            %{
              name: "acp/fixture",
              module: Catalyst.ACP.Workflow,
              source: {:application, {:acp_agent, "fixture"}}
            }} = Registry.resolve(workflow: "acp/fixture")

    assert Enum.any?(Registry.list(), &(&1.name == "acp/fixture"))

    Application.put_env(:catalyst, :acp_agents, [])
    assert {:error, {:unknown_acp_agent, "fixture"}} = Registry.resolve(workflow: "acp/fixture")
  end

  test "persisted templates resolve through the generic runner with pinned data" do
    template = template("review", "Review")
    digest = Template.digest(template)

    Application.put_env(:catalyst, :workflow_registry_test_templates, [template])

    assert {:ok,
            %{
              name: "review",
              module: Catalyst.Workflow.Runner,
              source: {:template, %{id: "review", name: "Review", version: 1, digest: ^digest}},
              template: ^template
            }} = Registry.resolve(workflow: "review")

    assert {:ok, Catalyst.Workflow.Runner} = Registry.fetch("review")
  end

  test "module workflows retain precedence over templates", %{owner: owner} do
    template = template("review", "Review")
    Application.put_env(:catalyst, :workflow_registry_test_templates, [template])
    Application.put_env(:catalyst, :workflows, %{"review" => WorkflowA})

    assert {:ok, %{module: WorkflowA, source: {:application, {:workflows, "review"}}}} =
             Registry.resolve(workflow: "review")

    assert :ok = Registry.register_workflow("review", WorkflowB, owner: owner)

    assert {:ok, %{module: WorkflowB, source: {:runtime, ^owner, {:workflow, "review"}}}} =
             Registry.resolve(workflow: "review")
  end

  test "list/0 includes templates and omits malformed template rows" do
    alpha = template("alpha", "Alpha")
    digest = Template.digest(alpha)

    Application.put_env(
      :catalyst,
      :workflow_registry_test_templates,
      [%{id: "  "}, alpha, :malformed]
    )

    assert Registry.list() == [
             %{name: :default, module: Catalyst.Agent.Loop, source: :builtin},
             %{
               name: "alpha",
               module: Catalyst.Workflow.Runner,
               source: {:template, %{id: "alpha", name: "Alpha", version: 1, digest: digest}},
               template: alpha
             }
           ]
  end

  defp template(id, name) do
    {:ok, template} =
      Template.new(%{
        "version" => 1,
        "id" => id,
        "name" => name,
        "description" => "Test workflow",
        "stages" => [
          %{
            "id" => "review",
            "name" => "Review",
            "prompt" => "Review the goal.",
            "preset" => "code_review",
            "tool_profile" => "inspect",
            "model" => "inherit",
            "reasoning_effort" => "high",
            "inputs" => ["goal"],
            "artifact" => "review",
            "inactivity_timeout_ms" => 30_000,
            "timeout_ms" => 60_000,
            "max_attempts" => 3
          }
        ]
      })

    template
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
    # Built-in-only baseline: exactly the default row.
    assert Registry.list() == [
             %{name: :default, module: Catalyst.Agent.Loop, source: :builtin}
           ]

    Application.put_env(:catalyst, :workflows, %{
      "zeta" => WorkflowA,
      "review" => WorkflowA,
      default: WorkflowB
    })

    assert :ok = Registry.register_workflow("review", WorkflowB, owner: owner)
    assert :ok = Registry.register_workflow("alpha", WorkflowA, owner: owner)

    assert Registry.list() == [
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
    assert Registry.list() == [
             %{name: "valid", module: WorkflowA, source: {:runtime, owner, {:workflow, "valid"}}}
           ]

    assert {:error, {:invalid_configuration, {:workflows, "review"}, NotAWorkflow}} =
             Registry.resolve(workflow: "review")

    # A malformed :workflows value degrades list/0 to the valid layers only.
    Application.put_env(:catalyst, :workflows, :malformed)

    assert Registry.list() == [
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

    assert true = :ets.delete(Registry.table())
    assert Registry.runtime_entries() == []
    assert {:ok, WorkflowA} = Registry.fetch("review")
    assert {:ok, %{module: WorkflowB}} = Registry.resolve([])

    extensions = Process.whereis(Catalyst.Extensions)
    assert is_pid(extensions)
    extensions_ref = Process.monitor(extensions)

    # Writes do not self-heal a sabotaged table (the registry owns its table
    # in init, like its sibling registries): the write crashes the process and
    # supervision restarts it with a fresh table, keeping the shared test VM
    # healthy without changing the missing-table read contract.
    pid = Process.whereis(Registry)
    ref = Process.monitor(pid)
    assert catch_exit(Registry.unregister_owner(owner))
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    new_pid = wait_for_restart(Registry, pid)
    _ = :sys.get_state(new_pid)
    assert is_reference(:ets.whereis(Registry.table()))
    assert_receive {:DOWN, ^extensions_ref, :process, ^extensions, _reason}
    assert_extension_runtime_ready(extensions)
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

  # Registry is in a :rest_for_one runtime. Seeing its replacement process is
  # not enough: downstream registries are still stopping and restarting, and
  # test teardown must not race that recovery or leak it into the next test.
  defp assert_extension_runtime_ready(old_pid) do
    _replacement = wait_for_restart(Catalyst.Extensions, old_pid)

    assert :ok = Catalyst.Extensions.await_ready(5_000)
  end

  defp ensure_registry_started do
    case Process.whereis(Registry) do
      nil -> start_supervised!(Registry)
      _pid -> :ok
    end
  end
end
