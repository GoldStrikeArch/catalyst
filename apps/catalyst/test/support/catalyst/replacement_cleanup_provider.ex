defmodule Catalyst.Test.ReplacementCleanupProvider do
  @moduledoc false

  @behaviour Catalyst.LLM.Provider

  @impl true
  def stream(model, context, opts, sink) do
    Catalyst.Test.SummaryCleanupProvider.stream(model, context, opts, sink)
  end

  @impl true
  def estimate_tokens(model, context, opts) do
    Catalyst.Test.SummaryCleanupProvider.estimate_tokens(model, context, opts)
  end

  @impl true
  def cleanup_session(session_id) do
    case Application.get_env(:catalyst, :summary_cleanup_test_pid) do
      pid when is_pid(pid) -> send(pid, {:summary_cleanup, __MODULE__, session_id})
      _none -> :ok
    end

    :ok
  end
end
