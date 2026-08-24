defmodule Catalyst.BuiltinExtensions.Shell do
  use Catalyst.Extension

  @impl true
  def metadata do
    %{name: "Shell sessions", description: "Cross-turn supervised PTY sessions"}
  end

  @impl true
  def setup(api) do
    with {:ok, _pid} <-
           Catalyst.ExtensionAPI.start_child(api, Catalyst.Features.ShellSupervisor) do
      case Catalyst.ExtensionAPI.register_tool(api, Catalyst.Tools.ShellSession) do
        :ok -> :ok
        {:ok, _entry} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end
end
