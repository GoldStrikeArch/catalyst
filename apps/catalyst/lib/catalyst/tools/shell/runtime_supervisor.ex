defmodule Catalyst.Tools.Shell.RuntimeSupervisor do
  @moduledoc """
  Supervises the ordered registry and process tree for persistent shell sessions.

  The dynamic supervisor depends on the registry. `:rest_for_one` preserves
  that ordering after a registry failure instead of leaving shell processes
  attached to stale registration state.
  """

  use Supervisor

  @doc "Start the persistent shell runtime supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Catalyst.Tools.Shell.Registry},
        {DynamicSupervisor, name: Catalyst.Tools.Shell.Supervisor, strategy: :one_for_one}
      ],
      strategy: :rest_for_one
    )
  end
end
