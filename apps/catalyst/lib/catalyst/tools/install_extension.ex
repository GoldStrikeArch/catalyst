defmodule Catalyst.Tools.InstallExtension do
  @moduledoc """
  General self-modification tool: write an Elixir source file that defines tools
  and/or a `Catalyst.Extension` (a module with `setup/1` that registers tools,
  LLM providers, agent-loop hooks, or UI pages/renderers via
  `Catalyst.ExtensionAPI`). It is compiled, loaded, version-controlled (git), and
  active immediately — no restart.

  Use `develop_tool` for the common case of a single new tool; use this when the
  file contributes more than one kind of thing (e.g. a provider + a hook).
  """
  use Catalyst.Tools.Tool

  alias Catalyst.Extensions.Installer

  import Catalyst.Tools.SelfModReport, only: [append_warning: 2]

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "install_extension"

  @impl true
  def description,
    do:
      "Install or update a Catalyst extension at runtime. Write a full Elixir source " <>
        "file: it may define tool modules (`use Catalyst.Tools.Tool`) and/or an extension " <>
        "module (`use Catalyst.Extension` with `setup(api)` that calls " <>
        "Catalyst.ExtensionAPI.register_tool/register_provider/register_hook/register_page/" <>
        "register_renderer). It compiles, loads, and activates immediately, and is committed " <>
        "to git for rollback. Namespace modules under Catalyst.Ext.*."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "extension file name (e.g. 'approval_gate')"
        },
        "source" => %{
          "type" => "string",
          "description" => "full Elixir source for the extension file"
        }
      },
      "required" => ["name", "source"]
    }
  end

  @impl true
  def execute(%{"name" => name, "source" => source}, _ctx) do
    case Installer.install(name, source) do
      {:ok, summary} ->
        result(describe(summary), summary)

      {:error, reason} ->
        raise "Failed to install the extension: #{Catalyst.Extensions.format_error(reason)}"
    end
  end

  defp describe(%{owner: owner, tools: tools, extensions: exts} = result) do
    parts =
      [
        tools != [] && "tools: #{Enum.join(tools, ", ")}",
        exts != [] && "extensions: #{Enum.map_join(exts, ", ", &inspect/1)}"
      ]
      |> Enum.filter(& &1)

    summary = if parts == [], do: "no tools/extensions found", else: Enum.join(parts, "; ")

    "Installed #{owner} (#{summary}). Active now."
    |> append_warning(result[:warning])
  end
end
