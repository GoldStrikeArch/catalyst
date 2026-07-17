defmodule Catalyst.Tools.ReloadTool do
  @moduledoc """
  Reload every extension file from disk (purge prior contributions + recompile).
  Use after editing files by hand, or to recover after a manual change. Files
  that fail to compile are listed in the result so the agent can fix them.
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
    {:ok, %{loaded: loaded, failed: failed}} = Extensions.load_all()

    case {loaded, failed} do
      {[], [_ | _]} ->
        raise "Reload failed — no extension file loaded.\n" <> format_failures(failed)

      _ ->
        tools = Enum.flat_map(loaded, & &1.tools)

        result(
          "Reloaded #{length(loaded)} file(s). Tools: #{Enum.join(tools, ", ")}" <>
            failures_section(failed),
          %{files: length(loaded), failed: length(failed)}
        )
    end
  end

  defp failures_section([]), do: ""

  defp failures_section(failed),
    do: "\n#{length(failed)} file(s) FAILED to load:\n" <> format_failures(failed)

  defp format_failures(failed) do
    Enum.map_join(failed, "\n", fn {path, reason} -> "  - #{path}: #{format_reason(reason)}" end)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
