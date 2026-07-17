defmodule Catalyst.LLM.OpenAICodex.StreamParserTest do
  use ExUnit.Case, async: true

  alias Catalyst.{Content, Message, Model}
  alias Catalyst.LLM.Event
  alias Catalyst.LLM.OpenAICodex.StreamParser

  defp model, do: %Model{id: "gpt-5.4", api: "openai-codex-responses", provider: "openai-codex"}

  defp run(events) do
    sink = fn ev -> send(self(), {:ev, ev}) end
    parser = Enum.reduce(events, StreamParser.new(), fn e, p -> StreamParser.handle(p, e, sink) end)
    StreamParser.finalize(parser, model())
  end

  test "assembles reasoning + a tool call into a tool_use assistant" do
    events = [
      %{"type" => "response.created", "response" => %{"id" => "resp_1"}},
      %{"type" => "response.output_item.added", "item" => %{"type" => "reasoning", "id" => "rs_1"}},
      %{"type" => "response.reasoning_text.delta", "delta" => "let me search"},
      %{"type" => "response.output_item.done",
        "item" => %{"type" => "reasoning", "id" => "rs_1", "summary" => [%{"text" => "search for TODO"}], "encrypted_content" => "ENC"}},
      %{"type" => "response.output_item.added",
        "item" => %{"type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "grep", "arguments" => ""}},
      %{"type" => "response.function_call_arguments.delta", "delta" => "{\"pattern\":"},
      %{"type" => "response.function_call_arguments.delta", "delta" => "\"TODO\"}"},
      %{"type" => "response.function_call_arguments.done", "arguments" => "{\"pattern\":\"TODO\"}"},
      %{"type" => "response.output_item.done",
        "item" => %{"type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "grep", "arguments" => "{\"pattern\":\"TODO\"}"}},
      %{"type" => "response.completed",
        "response" => %{"id" => "resp_1", "status" => "completed",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15, "input_tokens_details" => %{"cached_tokens" => 2}}}}
    ]

    assistant = run(events)

    assert assistant.stop_reason == :tool_use
    assert assistant.response_id == "resp_1"
    assert assistant.usage.input == 8
    assert assistant.usage.cache_read == 2
    assert assistant.usage.output == 5

    assert [%Content.Thinking{} = thinking, %Content.ToolCall{} = tool] = assistant.content

    # reasoning is captured whole (with encrypted_content) for replay
    assert thinking.thinking =~ "search for TODO"
    assert {:ok, %{"encrypted_content" => "ENC", "type" => "reasoning"}} = Jason.decode(thinking.signature)

    # tool-call id is "<call_id>|<item_id>"
    assert tool.id == "call_1|fc_1"
    assert tool.name == "grep"
    assert tool.arguments == %{"pattern" => "TODO"}

    assert_received {:ev, %Event.ToolCallStart{id: "call_1|fc_1", name: "grep"}}
    assert_received {:ev, %Event.ToolCallEnd{arguments: %{"pattern" => "TODO"}}}
  end

  test "assembles a plain text turn" do
    events = [
      %{"type" => "response.output_item.added", "item" => %{"type" => "message", "id" => "msg_1"}},
      %{"type" => "response.output_text.delta", "delta" => "Hello "},
      %{"type" => "response.output_text.delta", "delta" => "world"},
      %{"type" => "response.output_item.done", "item" => %{"type" => "message", "id" => "msg_1", "content" => [%{"type" => "output_text", "text" => "Hello world"}]}},
      %{"type" => "response.completed", "response" => %{"id" => "r", "status" => "completed"}}
    ]

    assistant = run(events)
    assert assistant.stop_reason == :stop
    assert Content.text_of(assistant.content) == "Hello world"
    assert_received {:ev, %Event.TextDelta{delta: "Hello "}}
  end

  test "surfaces a failed response as an error assistant" do
    events = [
      %{"type" => "response.failed", "response" => %{"error" => %{"code" => "rate_limit", "message" => "slow down"}}}
    ]

    assistant = run(events)
    assert assistant.stop_reason == :error
    assert assistant.error_message =~ "rate_limit"
    assert %Message.Assistant{} = assistant
  end
end
