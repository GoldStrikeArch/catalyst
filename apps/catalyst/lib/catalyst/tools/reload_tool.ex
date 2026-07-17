defmodule Catalyst.Tools.ReloadTool do
  @moduledoc """
  Reload every extension file from disk (purge prior contributions + recompile).
  Use after editing files by hand, or to recover after a manual change.
  """
  use Catalyst.Tools.Tool

  alias Catalyst.Extensions

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "reload_extensions"

  @impl true
  def description,
    do: "Reload all Catalyst extension files from ~/.catalyst/extensions (purge + recompile)."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl true
  def execute(_args, _ctx) do
    {:ok, summaries} = Extensions.load_all()
    tools = Enum.flat_map(summaries, & &1.tools)
    result("Reloaded #{length(summaries)} file(s). Tools: #{Enum.join(tools, ", ")}", %{files: length(summaries)})
  end
end
