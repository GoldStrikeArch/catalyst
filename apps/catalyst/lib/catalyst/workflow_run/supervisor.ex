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
      Supervisor.child_spec({Catalyst.WorkflowRun.Coordinator, opts},
        restart: :transient,
        significant: true
      )
    ]

    Supervisor.init(children,
      strategy: :one_for_all,
      max_restarts: 3,
      max_seconds: 5,
      auto_shutdown: :any_significant
    )
  end
end
