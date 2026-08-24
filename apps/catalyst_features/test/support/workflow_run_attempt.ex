defmodule Catalyst.Test.WorkflowRunAttempt do
  @moduledoc false

  @behaviour Catalyst.WorkflowRun.Attempt

  @impl true
  def run(context, emit) do
    owner = Process.whereis(Catalyst.WorkflowRunTest)
    send(owner, {:workflow_attempt, self(), context, emit})
    await_result(emit)
  end

  defp await_result(emit) do
    receive do
      {:return, result} ->
        result

      {:progress, event} ->
        emit.(event)
        await_result(emit)
    end
  end
end
