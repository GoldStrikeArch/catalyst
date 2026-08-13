defmodule Catalyst.WorkflowRun.Supervisor do
  @moduledoc false

  use Supervisor

  alias Catalyst.WorkflowRun.Names

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    Supervisor.start_link(__MODULE__, opts, name: Names.via(:supervisor, id))
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)

    children = [
      {Catalyst.WorkflowRun.AttemptSupervisor, id: id},
      {Catalyst.WorkflowRun.Coordinator, opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
