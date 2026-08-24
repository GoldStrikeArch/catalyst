defmodule Catalyst.WorkflowRun.AttemptWorker do
  @moduledoc false

  use GenServer, restart: :temporary

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, opts, {:continue, :run}}

  @impl true
  def handle_continue(:run, opts) do
    coordinator = Keyword.fetch!(opts, :coordinator)
    ref = Keyword.fetch!(opts, :ref)
    module = Keyword.fetch!(opts, :module)
    context = Keyword.fetch!(opts, :context)
    emit = &send(coordinator, {:attempt_progress, ref, &1})
    result = module.run(context, emit)
    send(coordinator, {:attempt_result, ref, result})
    {:stop, :normal, opts}
  end
end
