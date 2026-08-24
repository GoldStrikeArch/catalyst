defmodule Catalyst.Features.ShellSupervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Catalyst.Tools.Shell.Registry},
        {DynamicSupervisor, name: Catalyst.Tools.Shell.Supervisor, strategy: :one_for_one}
      ],
      strategy: :one_for_one
    )
  end
end
