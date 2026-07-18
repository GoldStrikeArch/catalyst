defmodule Catalyst.Test.ParentAbortProvider do
  @moduledoc false

  @behaviour Catalyst.LLM.Provider

  alias Catalyst.{Content, Message, Usage}
  alias Catalyst.LLM.Event

  @impl true
  def stream(model, _context, opts, sink) do
    session_id = Keyword.fetch!(opts, :session_id)

    case String.contains?(session_id, "_s") do
      true ->
        Catalyst.SubagentTestProvider.stream(
          model,
          %Catalyst.LLM.Context{},
          Keyword.put(opts, :subagent_test_mode, :block),
          sink
        )

      false ->
        tool_call(model, sink)
    end
  end

  defp tool_call(model, sink) do
    call = %Content.ToolCall{
      id: "parent-spawn-call",
      name: "spawn_agent",
      arguments: %{"agent" => "review", "task" => "Block until parent aborts."}
    }

    sink.(%Event.ToolCallStart{id: call.id, name: call.name})
    sink.(%Event.ToolCallEnd{id: call.id, name: call.name, arguments: call.arguments})

    {:ok,
     %Message.Assistant{
       content: [call],
       api: "parent-abort-test",
       provider: "parent-abort-test",
       model: model.id,
       usage: %Usage{},
       stop_reason: :tool_use,
       timestamp: Message.now()
     }}
  end
end
