defmodule Catalyst.SubagentTestProvider do
  @moduledoc """
  Deterministic provider used by child-session lifecycle tests.

  The selected mode comes from `opts[:subagent_test_mode]`. Blocking mode
  announces the child session and provider task to the test controller stored
  in `:catalyst, :subagent_test_controller`, then waits until the run is
  cancelled or the controller supplies a response.
  """

  @behaviour Catalyst.LLM.Provider

  alias Catalyst.{Content, Message, Usage}
  alias Catalyst.LLM.Event

  @impl true
  @spec stream(Catalyst.Model.t(), Catalyst.LLM.Context.t(), keyword(), function()) ::
          {:ok, Message.Assistant.t()} | {:error, term()}
  def stream(model, _context, opts, sink) do
    case Keyword.get(opts, :subagent_test_mode, {:text, :stop, "done"}) do
      {:error, reason} ->
        {:error, reason}

      {:text, stop_reason, text} ->
        respond(model, sink, stop_reason, text)

      :block ->
        block(model, opts, sink)
    end
  end

  defp block(model, opts, sink) do
    session_id = Keyword.fetch!(opts, :session_id)

    case Application.fetch_env(:catalyst, :subagent_test_controller) do
      {:ok, controller} when is_pid(controller) ->
        send(controller, {:subagent_provider_started, session_id, self()})

      _missing ->
        :ok
    end

    receive do
      {:subagent_provider_reply, stop_reason, text} ->
        respond(model, sink, stop_reason, text)
    end
  end

  defp respond(model, sink, stop_reason, text) do
    sink.(%Event.TextStart{})
    sink.(%Event.TextDelta{delta: text})
    sink.(%Event.TextEnd{})

    {:ok,
     %Message.Assistant{
       content: Content.text(text),
       api: "subagent-test",
       provider: "subagent-test",
       model: model && model.id,
       usage: %Usage{},
       stop_reason: stop_reason,
       timestamp: Message.now()
     }}
  end
end
