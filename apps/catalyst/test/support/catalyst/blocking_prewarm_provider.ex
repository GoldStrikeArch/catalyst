defmodule Catalyst.Test.BlockingPrewarmProvider do
  @moduledoc false

  @behaviour Catalyst.LLM.Provider

  alias Catalyst.LLM.OpenAICodex.{ConnCache, WebSocket}

  @impl true
  def stream(model, _context, _opts, _sink) do
    {:ok,
     %Catalyst.Message.Assistant{
       content: Catalyst.Content.text("unused"),
       model: model.id,
       stop_reason: :stop,
       timestamp: Catalyst.Message.now()
     }}
  end

  # The impossible Mint connection is an intentional sentinel: this branch only
  # runs when prewarm cancellation fails, and lets the regression test observe a
  # late cache insertion without opening a real socket.
  @dialyzer {:nowarn_function, prewarm: 3}
  def prewarm(_model, _context, opts) do
    test = Application.fetch_env!(:catalyst, :blocking_prewarm_test)
    send(test, {:blocking_prewarm_started, self()})
    send(test, {:blocking_prewarm_opts, opts})

    receive do
      :finish_prewarm -> :ok
    end

    session_id = Keyword.fetch!(opts, :session_id)
    ConnCache.stash_owned(session_id, url(), socket(), nil)
    send(test, :blocking_prewarm_stashed)
    :ok
  end

  @impl true
  def cleanup_session(session_id), do: ConnCache.drop(session_id)

  defp url, do: "wss://example.test"

  defp socket do
    %WebSocket{conn: :late_prewarm, websocket: %Mint.WebSocket{}, ref: make_ref()}
  end
end
