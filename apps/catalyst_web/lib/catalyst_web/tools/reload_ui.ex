defmodule CatalystWeb.Tools.ReloadUi do
  @moduledoc """
  Self-modification tool: reload the UI so structural page/layout/render changes
  (hot-swapped LiveView/component modules) take effect in already-connected windows.
  """
  use Catalyst.Tools.Tool

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "reload_ui"

  @impl true
  def description,
    do:
      "Reload connected windows to apply UI/render changes (hot-swapped pages/components/renderers)."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl true
  def execute(_args, _ctx) do
    CatalystWeb.Assets.reload()
    result("Requested a UI reload.")
  end
end
