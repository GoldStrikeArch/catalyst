defmodule Catalyst.BuiltinExtensions.FeaturePages do
  use Catalyst.Extension

  @impl true
  def metadata do
    %{name: "Feature pages", description: "Computer, workflows, and model comparison UI"}
  end

  @impl true
  def setup(api) do
    with :ok <-
           Catalyst.ExtensionAPI.register_page(
             api,
             "computer",
             CatalystWeb.Pages.ComputerPage,
             label: "Computer",
             render_mode: :live
           ),
         :ok <-
           Catalyst.ExtensionAPI.register_page(
             api,
             "workflows",
             CatalystWeb.Pages.WorkflowsPage,
             label: "Workflows",
             render_mode: :live
           ) do
      Catalyst.ExtensionAPI.register_page(
        api,
        "compare",
        CatalystWeb.Pages.ComparisonPage,
        label: "Compare",
        match: :prefix,
        render_mode: :live
      )
    end
  end
end
