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

  alias Catalyst.Extensions

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
    dir = Extensions.dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, sanitize(name) <> ".ex")
    File.write!(path, source)

    case Extensions.load_file(path) do
      {:ok, %{tools: []}} ->
        raise "Compiled #{path} but found no tool module. Did you `use Catalyst.Tools.Tool` and implement name/0, parameters/0, execute/2?"

      {:ok, %{tools: tool_names}} ->
        result(
          "Created and loaded #{length(tool_names)} tool(s): #{Enum.join(tool_names, ", ")}. " <>
            "They are available to call now (next turn).",
          %{path: path, tools: tool_names}
        )

      {:error, reason} ->
        raise "Failed to compile the new tool: #{reason}"
    end
  end

  defp sanitize(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "ext_#{System.unique_integer([:positive])}"
      ok -> ok
    end
  end
end
