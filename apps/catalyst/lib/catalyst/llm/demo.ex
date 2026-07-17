defmodule Catalyst.LLM.Demo do
  @moduledoc """
  An offline, input-aware provider for trying the GUI without a login.

  It runs one real tool against the working directory based on the user's
  message (a search, or a directory listing), then replies with a short summary.
  Text is streamed word-by-word (with a tiny delay) so the streaming UI is
  visible. Swap in `Catalyst.LLM.OpenAICodex.Provider` for real answers.
  """
  @behaviour Catalyst.LLM.Provider

  alias Catalyst.{Content, Message, Model, Usage}
  alias Catalyst.LLM.Event

  @word_delay_ms 12

  @doc "A `%Model{}` tag for the demo provider."
  def model, do: %Model{id: "demo", name: "Demo (offline)", api: "demo", provider: "demo"}

  @impl true
  def stream(model, context, _opts, sink) do
    assistant =
      case List.last(context.messages) do
        %Message.ToolResult{} = result -> finalize(model, context, result)
        _ -> next_tool(model, context)
      end

    emit(assistant, sink)
    {:ok, assistant}
  end

  # First turn: pick a tool from the user's message.
  defp next_tool(model, context) do
    {note, name, args} = choose_tool(last_user_text(context))

    %Message.Assistant{
      content: [%Content.Text{text: note}, tool_call(name, args)],
      api: "demo",
      provider: "demo",
      model: model.id,
      usage: %Usage{},
      stop_reason: :tool_use,
      timestamp: Message.now()
    }
  end

  # Second turn: summarize the tool output.
  defp finalize(model, context, result) do
    preview =
      result.content
      |> Content.text_of()
      |> String.split("\n", trim: true)
      |> Enum.take(8)
      |> Enum.join("\n")

    you_said = last_user_text(context)

    text =
      """
      Here's what `#{result.tool_name}` returned:

      #{preview}

      You asked: "#{you_said}". This is the offline Demo provider — run `mix catalyst.login` and switch to Codex for real answers.
      """
      |> String.trim()

    text_message(model, text)
  end

  defp choose_tool(text) do
    cond do
      match = Regex.run(~r/(?:grep|search|look for)\s+["']?([^\s"']+)/i, text) ->
        word = Enum.at(match, 1)
        {"Let me search for \"#{word}\".", "grep", %{"pattern" => word}}

      Regex.match?(~r/(?:find|locate)\s+/i, text) ->
        {"Let me find matching files.", "find", %{"pattern" => "*"}}

      true ->
        {"Let me look at what's in this directory.", "ls", %{}}
    end
  end

  defp last_user_text(context) do
    context.messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %Message.User{content: c} -> Content.text_of(c)
      _ -> false
    end)
  end

  defp text_message(model, text) do
    %Message.Assistant{
      content: [%Content.Text{text: text}],
      api: "demo",
      provider: "demo",
      model: model.id,
      usage: %Usage{},
      stop_reason: :stop,
      timestamp: Message.now()
    }
  end

  defp tool_call(name, args),
    do: %Content.ToolCall{id: "demo_#{System.unique_integer([:positive])}", name: name, arguments: args}

  defp emit(assistant, sink) do
    sink.(%Event.Start{partial: assistant})

    Enum.each(assistant.content, fn
      %Content.Text{text: t} ->
        sink.(%Event.TextStart{})
        stream_words(t, sink)
        sink.(%Event.TextEnd{})

      %Content.ToolCall{id: id, name: n, arguments: a} ->
        sink.(%Event.ToolCallStart{id: id, name: n})
        sink.(%Event.ToolCallEnd{id: id, name: n, arguments: a})

      _ ->
        :ok
    end)

    sink.(%Event.Done{reason: assistant.stop_reason, message: assistant})
  end

  defp stream_words(text, sink) do
    text
    |> String.split(~r/(\s+)/, include_captures: true)
    |> Enum.each(fn chunk ->
      if String.trim(chunk) != "", do: Process.sleep(@word_delay_ms)
      sink.(%Event.TextDelta{delta: chunk})
    end)
  end
end
