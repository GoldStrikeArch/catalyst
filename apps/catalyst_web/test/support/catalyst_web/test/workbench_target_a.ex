defmodule CatalystWeb.Test.WorkbenchTargetA do
  @moduledoc false

  use CatalystWeb, :html

  def render(assigns) do
    ~H"""
    <main id="workbench-target-a" data-busy={map_size(@workbench_state.busy)}>
      <p id="workbench-target-a-output">{@workbench_state.output}</p>
      <button id="workbench-target-a-transition" phx-click="workbench:ide:palette-toggle">
        Transition
      </button>
      <button id="workbench-target-a-remount" phx-click="workbench:host:remount">
        Apply active
      </button>
      <button
        id="workbench-target-a-change"
        phx-click="workbench:test:target"
        phx-value-target="chat"
      >
        Change target
      </button>
    </main>
    """
  end
end
