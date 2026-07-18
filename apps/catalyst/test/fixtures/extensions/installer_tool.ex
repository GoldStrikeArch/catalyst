defmodule Catalyst.Ext.InstallerCounter do
  @moduledoc false

  @owner "installer_tool"

  @doc false
  def start_link(_opts), do: Agent.start_link(fn -> 0 end)

  @doc false
  def bump, do: Agent.update(process!(), &(&1 + 1))

  @doc false
  def count, do: Agent.get(process!(), & &1)

  defp process! do
    case Catalyst.Extensions.Processes.list(@owner) do
      [pid] -> pid
      _other -> raise "installer observer counter is not running"
    end
  end
end

defmodule Catalyst.Ext.InstallMoreTool do
  @moduledoc false

  use Catalyst.Tools.Tool

  @child_source ~S'''
  defmodule Catalyst.Ext.FlexInstalledChild do
    use Catalyst.Tools.Tool

    @impl true
    def name, do: "flex_child"

    @impl true
    def description, do: "A tool installed by another extension during an agent run."

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def execute(_args, _ctx), do: result("FLEX-CHILD-RAN")
  end
  '''

  @impl true
  def name, do: "install_more"

  @impl true
  def description, do: "Install a second fixture extension while the loop is running."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl true
  def execute(_args, _ctx) do
    case Catalyst.Extensions.Installer.install(
           "flex_installed_child",
           @child_source,
           "flex child"
         ) do
      {:ok, _summary} -> result("INSTALLED-MORE")
      {:error, reason} -> raise Catalyst.Extensions.format_error(reason)
    end
  end
end

defmodule Catalyst.Ext.InstallerToolExtension do
  @moduledoc false

  use Catalyst.Extension

  @impl true
  def setup(api) do
    counter = %{
      id: Catalyst.Ext.InstallerCounter,
      start: {Catalyst.Ext.InstallerCounter, :start_link, [[]]},
      restart: :temporary
    }

    {:ok, _pid} = Catalyst.ExtensionAPI.start_child(api, counter)
    Catalyst.ExtensionAPI.on(api, &__MODULE__.observe/1)
  end

  @doc false
  def observe(%Catalyst.Agent.Event.ToolExecutionEnd{}) do
    Catalyst.Ext.InstallerCounter.bump()
  end

  def observe(_event), do: :ok
end
