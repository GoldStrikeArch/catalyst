defmodule Catalyst.LLM.Faux do
  @moduledoc """
  A scripted provider for driving the agent loop with no network (PI's `faux`).

  The script is a list of per-turn responses passed via `opts[:script]`. The turn
  index is the number of assistant messages already in the context, so it's
  deterministic and stateless. Past the end of the script it returns a plain
  "done" text turn.

  Script entries:

      {:text, "all done"}                         # a final text turn (stop)
      {:tool, "read", %{"path" => "x"}}           # one tool call (tool_use)
      {:tools, [{"read", %{}}, {"grep", %{}}]}    # parallel tool calls
      {:text_then_tool, "looking…", "grep", %{}}  # text + a tool call
  """
  @behaviour Catalyst.LLM.Provider

  alias Catalyst.{Content, Message, Usage}
  alias Catalyst.LLM.Event

  @impl true
  def stream(model, context, opts, sink) do
    script = Keyword.get(opts, :script, [])
    turn = Enum.count(context.messages, &match?(%Message.Assistant{}, &1))
    spec = Enum.at(script, turn, {:text, "done"})

    assistant = build(spec, model)
    emit_events(assistant, sink)
    {:ok, assistant}
  end

  defp build({:text, text}, model), do: assistant([%Content.Text{text: text}], :stop, model)
  defp build({:tool, name, args}, model), do: assistant([tool_call(name, args)], :tool_use, model)

  defp build({:tools, calls}, model),
    do: assistant(Enum.map(calls, fn {n, a} -> tool_call(n, a) end), :tool_use, model)

  defp build({:text_then_tool, text, name, args}, model),
    do: assistant([%Content.Text{text: text}, tool_call(name, args)], :tool_use, model)

  defp assistant(content, reason, model) do
    %Message.Assistant{
      content: content,
      api: "faux",
      provider: "faux",
      model: model && model.id,
      usage: %Usage{},
      stop_reason: reason,
      timestamp: Message.now()
    }
  end

  defp tool_call(name, args) do
    %Content.ToolCall{
      id: "call_#{System.unique_integer([:positive])}",
      name: name,
      arguments: args
    }
  end

  defp emit_events(assistant, sink) do
    Enum.each(assistant.content, fn
      %Content.Text{text: t} ->
        sink.(%Event.TextStart{})
        sink.(%Event.TextDelta{delta: t})
        sink.(%Event.TextEnd{})

      %Content.ToolCall{id: id, name: n, arguments: a} ->
        sink.(%Event.ToolCallStart{id: id, name: n})
        sink.(%Event.ToolCallEnd{id: id, name: n, arguments: a})

      _ ->
        :ok
    end)
  end
end
