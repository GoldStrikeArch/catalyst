defmodule CatalystWeb.Test.WorkbenchTargetB do
  @moduledoc false

  use CatalystWeb, :html

  def render(assigns) do
    ~H"""
    <main id="workbench-target-b" data-busy={map_size(@workbench_state.busy)}>
      <p id="workbench-target-b-output">{@workbench_state.output}</p>
    </main>
    """
  end
end
