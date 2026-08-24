defmodule Catalyst.WorkflowRun.AttemptSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias Catalyst.WorkflowRun.Names

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: Names.via(:attempt_supervisor, id))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
