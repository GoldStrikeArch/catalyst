defmodule Catalyst.BuiltinExtensions.Computer do
  use Catalyst.Extension

  @tools [Catalyst.Tools.Computer]

  @impl true
  def metadata do
    %{name: "Computer use", description: "Screenshots and native desktop input"}
  end

  @impl true
  def setup(api) do
    with {:ok, _pid} <-
           Catalyst.ExtensionAPI.start_child(api, Catalyst.Features.ComputerSupervisor),
         :ok <- register_tools(api),
         :ok <-
           Catalyst.ExtensionAPI.register_capability(
             api,
             :computer_use,
             &Catalyst.Tools.Computer.Availability.granted?/1
           ) do
      Catalyst.ExtensionAPI.register_hook(
        api,
        :transform_context,
        &Catalyst.Tools.Computer.Screenshots.prune_hook/2,
        id: :computer_screenshot_prune
      )
    end
  end

  defp register_tools(api) do
    Enum.reduce_while(@tools, :ok, fn tool, :ok ->
      case Catalyst.ExtensionAPI.register_tool(api, tool) do
        :ok -> {:cont, :ok}
        {:ok, _entry} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
