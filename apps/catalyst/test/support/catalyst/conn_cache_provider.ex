defmodule Catalyst.Test.ConnCacheProvider do
  @moduledoc false

  @behaviour Catalyst.LLM.Provider

  alias Catalyst.LLM.OpenAICodex.ConnCache

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

  @impl true
  def cleanup_session(session_id), do: ConnCache.drop(session_id)
end
