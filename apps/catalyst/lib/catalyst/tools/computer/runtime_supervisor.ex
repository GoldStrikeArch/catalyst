defmodule Catalyst.Tools.Computer.RuntimeSupervisor do
  @moduledoc """
  Supervises the stateful Computer Use runtime owned by its capability pack.

  `Viewport` owns screenshot geometry independently from `Helper`, so a helper
  crash and restart cannot discard the coordinate mapping used by the next
  input action. The helper remains lazy and opens its native port only when a
  Computer Use call needs it.
  """

  use Supervisor

  @doc "Start the Computer Use runtime supervisor."
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
