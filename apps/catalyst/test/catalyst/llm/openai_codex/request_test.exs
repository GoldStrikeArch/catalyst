defmodule Catalyst.LLM.OpenAICodex.RequestTest do
  use ExUnit.Case, async: true

  alias Catalyst.{Content, Message, Model}
  alias Catalyst.LLM.Context
  alias Catalyst.LLM.OpenAICodex.Request

  defp model, do: %Model{id: "gpt-5.4", api: "openai-codex-responses", provider: "openai-codex"}

  test "builds Responses input: system prompt, reasoning replay, tool call + result" do
    reasoning_item = %{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "ENC"}

    messages = [
      Message.user("rewrite it"),
      %Message.Assistant{
        content: [
          %Content.Thinking{thinking: "...", signature: Jason.encode!(reasoning_item)},
          %Content.ToolCall{id: "call_1|fc_1", name: "grep", arguments: %{"pattern" => "x"}}
        ],
        stop_reason: :tool_use
      },
      %Message.ToolResult{
        tool_call_id: "call_1|fc_1",
        tool_name: "grep",
        content: [%Content.Text{text: "match found"}],
        is_error: false
      }
    ]

    tools = [%{name: "grep", description: "search", parameters: %{"type" => "object"}}]
    context = %Context{system_prompt: "You are Catalyst.", messages: messages, tools: tools}

    body = Request.build(model(), context, session_id: "sess-1")

    assert body["instructions"] == "You are Catalyst."
    assert body["include"] == ["reasoning.encrypted_content"]
    assert body["prompt_cache_key"] == "sess-1"
    assert body["store"] == false
    assert body["tool_choice"] == "auto"

    input = body["input"]

    # user input_text
    assert Enum.any?(
             input,
             &match?(
               %{
                 "role" => "user",
                 "content" => [%{"type" => "input_text", "text" => "rewrite it"}]
               },
               &1
             )
           )

    # reasoning item replayed verbatim (with encrypted_content)
    assert Enum.any?(input, &(&1 == reasoning_item))

    # function_call: id/call_id split out of "call_1|fc_1", args re-encoded as a string
    assert Enum.any?(input, fn item ->
             item["type"] == "function_call" and item["call_id"] == "call_1" and
               item["id"] == "fc_1" and item["name"] == "grep" and
               item["arguments"] == ~s({"pattern":"x"})
           end)

    # function_call_output keyed by the call_id only
    assert Enum.any?(
             input,
             &match?(
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_1",
                 "output" => "match found"
               },
               &1
             )
           )

    # tools converted to function tools
    assert [%{"type" => "function", "name" => "grep", "strict" => nil}] = body["tools"]
  end

  test "omits tools and reasoning when not provided; defaults instructions" do
    context = %Context{system_prompt: nil, messages: [Message.user("hi")], tools: []}
    body = Request.build(model(), context, [])

    assert body["instructions"] == "You are a helpful assistant."
    refute Map.has_key?(body, "tools")
    refute Map.has_key?(body, "reasoning")
  end

  test "includes reasoning config when an effort is set" do
    context = %Context{messages: [Message.user("hi")], tools: []}
    body = Request.build(model(), context, reasoning_effort: "high")
    assert body["reasoning"] == %{"effort" => "high", "summary" => "auto"}
  end
end
