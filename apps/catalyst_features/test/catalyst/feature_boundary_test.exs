defmodule Catalyst.FeatureBoundaryTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.{Content, Message}
  alias Catalyst.Session.{Manager, Server}
  alias Catalyst.Workflow.{Registry, Store, Template}

  defmodule WorkflowOverride do
    @behaviour Catalyst.Workflow

    @impl true
    def run(_prompts, context, _config, _emit), do: {:ok, [], context}
  end

  setup do
    previous = %{
      acp_agents: Application.fetch_env(:catalyst, :acp_agents),
      workflows: Application.fetch_env(:catalyst, :workflows)
    }

    Application.delete_env(:catalyst, :acp_agents)
    Application.delete_env(:catalyst, :workflows)

    on_exit(fn ->
      Registry.unregister_owner("feature-boundary-test")
      restore_env(:acp_agents, previous.acp_agents)
      restore_env(:workflows, previous.workflows)
    end)

    :ok
  end

  test "immutable bundled sources activate shipped providers through the public registry" do
    assert {:ok, Catalyst.LLM.GrokSubscription.Provider} =
             Catalyst.LLM.Registry.fetch("grok-subscription-chat-completions")

    assert Enum.any?(Catalyst.Extensions.list_loaded(), &(&1.owner == "grok_subscription"))
  end

  test "the ACP workflow source resolves configured external agents" do
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
  end

  test "the template source resolves pinned data below application and runtime overrides" do
    assert {:ok, template} = Store.fetch("research")
    digest = Template.digest(template)

    assert {:ok,
            %{
              name: "research",
              module: Catalyst.Workflow.Runner,
              source:
                {:template,
                 %{id: "research", name: template_name, version: 1, digest: ^digest}},
              template: ^template
            }} = Registry.resolve(workflow: "research")

    assert template_name == template.name

    Application.put_env(:catalyst, :workflows, %{"research" => WorkflowOverride})

    assert {:ok,
            %{module: WorkflowOverride, source: {:application, {:workflows, "research"}}}} =
             Registry.resolve(workflow: "research")

    assert :ok =
             Registry.register_workflow("research", WorkflowOverride,
               owner: "feature-boundary-test"
             )

    assert {:ok,
            %{
              module: WorkflowOverride,
              source: {:runtime, "feature-boundary-test", {:workflow, "research"}}
            }} = Registry.resolve(workflow: "research")
  end

  test "a populated ACP session rejects changing its explicit agent identity" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "catalyst_feature_boundary_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(
        cwd: tmp,
        provider: nil,
        model: nil,
        opts: [
          loop: Catalyst.ACP.Workflow,
          acp_agent: %{id: "first"}
        ]
      )

    on_exit(fn -> Manager.stop(id) end)

    assert :ok =
             Server.append_recovered(pid, %Message.Assistant{
               content: Content.text("existing"),
               timestamp: Message.now()
             })

    assert {:error, :backend_switch_requires_new_session} =
             Server.configure(pid, opts: [acp_agent: %{id: "second"}])

    assert Server.state(pid).opts[:acp_agent] == %{id: "first"}
  end
end
