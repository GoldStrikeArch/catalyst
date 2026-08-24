defmodule Catalyst.BuiltinExtensions.ExternalAgents do
  use Catalyst.Extension

  @impl true
  def metadata do
    %{
      name: "External agents",
      description: "Providerless Claude Code and ACP workflows bundled with Catalyst"
    }
  end

  @impl true
  def setup(api) do
    with {:ok, _pid} <- Catalyst.ExtensionAPI.start_child(api, Catalyst.ACP.Supervisor),
         :ok <-
           Catalyst.ExtensionAPI.register_workflow_source(
             api,
             Catalyst.ACP.WorkflowSource
           ) do
      Catalyst.ExtensionAPI.register_workflow(
        api,
        "claude-code",
        Catalyst.ClaudeCode.Workflow
      )
    end
  end
end
