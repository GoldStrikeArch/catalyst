defmodule Catalyst.Tools.DevelopTool do
  @moduledoc """
  Lets the agent extend itself: write a new tool as an Elixir module and load it
  into the running VM immediately (no restart). The module must `use
  Catalyst.Tools.Tool` and implement `name/0`, `description/0`, `parameters/0`,
  and `execute/2`. The source is saved to the extensions directory so it persists
  and is reloaded on the next boot.

  This is full code execution by design (the user's own agent on their machine),
  the BEAM analog of PI's self-developing tools.
  """
  use Catalyst.Tools.Tool

  alias Catalyst.Extensions.Installer

  import Catalyst.Tools.SelfModReport, only: [append_warning: 2]

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "develop_tool"

  @impl true
  def description,
    do:
      "Create a NEW tool for yourself by writing an Elixir module that `use`s " <>
        "Catalyst.Tools.Tool (implementing name/0, description/0, parameters/0, " <>
        "execute/2). It is compiled and loaded immediately and usable on the next " <>
        "turn. Use this to build capabilities you don't yet have."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "Short identifier for the extension file (e.g. 'word_count')"
        },
        "source" => %{
          "type" => "string",
          "description" =>
            "Full Elixir source of a module that `use Catalyst.Tools.Tool` and implements " <>
              "name/0, description/0, parameters/0, execute/2. Build the result with result(text, details \\\\ %{})."
        }
      },
      "required" => ["name", "source"]
    }
  end

  @impl true
  def execute(%{"name" => name, "source" => source}, _ctx) do
    # Same write/restore/commit pipeline as install_extension, so develop_tool
    # changes are git-versioned and rollback_extension can revert them.
    case Installer.install(name, source, "develop_tool") do
      {:ok, %{tools: [], path: path}} ->
        raise "Compiled #{path} but found no tool module. Did you `use Catalyst.Tools.Tool` and implement name/0, parameters/0, execute/2?"

      {:ok, %{tools: tool_names} = summary} ->
        result(
          ("Created and loaded #{length(tool_names)} tool(s): #{Enum.join(tool_names, ", ")}. " <>
             "They are available to call now (next turn).")
          |> append_warning(summary[:warning]),
          Map.take(summary, [:path, :tools, :warning])
        )

      {:error, reason} ->
        raise "Failed to create the new tool: #{Catalyst.Extensions.format_error(reason)}"
    end
  end
end
