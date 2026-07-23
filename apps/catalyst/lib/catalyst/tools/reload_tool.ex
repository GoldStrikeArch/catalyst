defmodule Catalyst.Tools.ReloadTool do
  @moduledoc """
  Reload every extension file from disk (purge prior contributions + recompile).
  Use after editing files by hand, or to recover after a manual change. Files
  that fail to compile are listed in the result so the agent can fix them.
  """
  use Catalyst.Tools.Tool

  alias Catalyst.Extensions

  import Catalyst.Tools.SelfModReport, only: [failures_section: 1, format_failures: 1]

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
    case Extensions.load_all() do
      {:ok, load_result} -> format_result(load_result)
      {:error, reason} -> raise "Reload failed: " <> Extensions.format_error(reason)
    end
  end

  defp format_result(%{loaded: loaded, failed: failed}) do
    case {loaded, failed} do
      {[], [_ | _]} ->
        raise "Reload failed — no extension file loaded.\n" <> format_failures(failed)

      _ ->
        tools = Enum.flat_map(loaded, & &1.tools)

        result(
          "Reloaded #{length(loaded)} file(s). Tools: #{Enum.join(tools, ", ")}" <>
            failures_section(failed) <> warnings_section(loaded),
          %{
            files: length(loaded),
            failed: length(failed),
            warnings: Enum.count(loaded, &is_binary(&1[:warning]))
          }
        )
    end
  end

  defp warnings_section(loaded) do
    warnings =
      for summary <- loaded,
          warning = summary[:warning],
          is_binary(warning),
          do: "  - #{summary.owner}: #{warning}"

    case warnings do
      [] ->
        ""

      warnings ->
        "\n#{length(warnings)} file(s) loaded with WARNINGS:\n" <> Enum.join(warnings, "\n")
    end
  end
end
