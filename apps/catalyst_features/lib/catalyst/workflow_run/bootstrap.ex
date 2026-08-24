defmodule Catalyst.WorkflowRun.Bootstrap do
  @moduledoc false

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec start_link(keyword()) :: :ignore
  def start_link(_opts) do
    :ok = Catalyst.WorkflowRun.Store.interrupt_all()
    :ignore
  end
end
