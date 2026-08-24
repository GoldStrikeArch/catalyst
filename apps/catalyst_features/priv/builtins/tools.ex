defmodule Catalyst.BuiltinExtensions.Tools do
  use Catalyst.Extension

  @tools [
    Catalyst.Tools.Fetch,
    Catalyst.Tools.AppleScript,
    Catalyst.Tools.OpenApp,
    Catalyst.Tools.ListApps,
    Catalyst.Tools.Clipboard
  ]

  @impl true
  def metadata do
    %{name: "Bundled tools", description: "Fetch and desktop automation tools"}
  end

  @impl true
  def setup(api) do
    Enum.reduce_while(@tools, :ok, fn tool, :ok ->
      case Catalyst.ExtensionAPI.register_tool(api, tool) do
        :ok -> {:cont, :ok}
        {:ok, _entry} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
