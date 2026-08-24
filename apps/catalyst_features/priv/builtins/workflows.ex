defmodule Catalyst.BuiltinExtensions.Workflows do
  use Catalyst.Extension

  @impl true
  def metadata do
    %{name: "Workflow orchestration", description: "Templates and durable staged workflow runs"}
  end

  @impl true
  def setup(api) do
    with {:ok, _pid} <-
           Catalyst.ExtensionAPI.start_child(api, Catalyst.Features.WorkflowSupervisor) do
      Catalyst.ExtensionAPI.register_workflow_source(
        api,
        Catalyst.Workflow.TemplateSource
      )
    end
  end
end
