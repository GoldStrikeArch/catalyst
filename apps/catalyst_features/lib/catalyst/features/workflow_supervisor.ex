defmodule Catalyst.Features.WorkflowSupervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Catalyst.WorkflowRun.Registry},
        {DynamicSupervisor,
         name: Catalyst.WorkflowRun.DynamicSupervisor,
         strategy: :one_for_one,
         max_restarts: 100,
         max_seconds: 5},
        Catalyst.WorkflowRun.Bootstrap
      ],
      strategy: :one_for_one
    )
  end
end
