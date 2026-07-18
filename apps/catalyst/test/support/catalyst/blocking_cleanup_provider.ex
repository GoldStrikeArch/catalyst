defmodule Catalyst.Test.BlockingCleanupProvider do
  @moduledoc false

  @behaviour Catalyst.LLM.Provider

  @impl true
  def stream(_model, _context, _opts, _sink), do: {:error, :not_supported}

  @impl true
  def cleanup_session(session_id) do
    case Application.get_env(:catalyst, :blocking_cleanup_test_pid) do
      pid when is_pid(pid) ->
        send(pid, {:blocking_cleanup_started, self(), session_id})

        receive do
          {:release_cleanup, ^session_id} -> :ok
        end

      _none ->
        :ok
    end
  end
end
