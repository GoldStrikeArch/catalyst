defmodule Catalyst.Features.ComputerSupervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [Catalyst.Tools.Computer.Viewport, Catalyst.Tools.Computer.Helper],
      strategy: :one_for_one
    )
  end
end
