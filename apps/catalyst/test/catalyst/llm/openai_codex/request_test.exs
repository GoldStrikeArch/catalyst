defmodule Catalyst.LLM.OpenAICodex.RequestTest do
  use ExUnit.Case, async: true

  alias Catalyst.{Content, Message, Model}
  alias Catalyst.Context.Tokens
  alias Catalyst.LLM.Context
  alias Catalyst.LLM.OpenAICodex.{Provider, Request}

  defmodule UnknownBlock do
    @moduledoc false
    defstruct [:data]
  end

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

    assert String.starts_with?(body["instructions"], "You are Catalyst.\n\n")
    assert body["instructions"] =~ ~s(exact model identifier "gpt-5.4")
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

  # Websocket streams attach stream-position bookkeeping to reasoning items;
  # replaying `output_index` is rejected by the backend with a 400
  # `unknown_parameter`, so it must never reach the wire (including from
  # transcripts persisted before this fix).
  test "reasoning replay strips stream-position fields from the stored signature" do
    stored = %{
      "type" => "reasoning",
      "id" => "rs_1",
      "encrypted_content" => "ENC",
      "summary" => [%{"type" => "summary_text", "text" => "thinking"}],
      "output_index" => 0,
      "sequence_number" => 7
    }

    messages = [
      %Message.Assistant{
        content: [%Content.Thinking{thinking: "...", signature: Jason.encode!(stored)}],
        stop_reason: :tool_use
      }
    ]

    assert [replayed] = Request.input_items(messages, model())
    assert replayed == Map.drop(stored, ["output_index", "sequence_number"])
  end

  test "omits tools and reasoning when not provided; defaults instructions" do
    context = %Context{system_prompt: nil, messages: [Message.user("hi")], tools: []}
    body = Request.build(model(), context, [])

    assert String.starts_with?(body["instructions"], "You are a helpful assistant.\n\n")
    assert body["instructions"] =~ ~s(exact model identifier "gpt-5.4")
    refute Map.has_key?(body, "tools")
    refute Map.has_key?(body, "reasoning")
  end

  test "instructions identify the selected request model without injecting a stale default" do
    selected = %Model{
      model()
      | id: "gpt-5.6-luna",
        name: "GPT-5.6-Luna"
    }

    context = %Context{
      system_prompt: "Keep this custom prompt byte-for-byte.",
      messages: [],
      tools: []
    }

    body = Request.build(selected, context)

    assert String.starts_with?(
             body["instructions"],
             "Keep this custom prompt byte-for-byte.\n\nRuntime model identity:"
           )

    assert body["instructions"] =~ ~s(exact model identifier "gpt-5.6-luna")
    assert body["instructions"] =~ "report that identifier exactly"
    refute body["instructions"] =~ "gpt-5.4"
    assert body["model"] == "gpt-5.6-luna"
  end

  test "tool-result images ship as an input_image part list for vision models" do
    result = %Message.ToolResult{
      tool_call_id: "call_1|fc_1",
      tool_name: "read",
      content: [
        %Content.Text{text: "Read image file [image/png]"},
        %Content.Image{data: "QUJD", mime_type: "image/png"}
      ]
    }

    vision = %Model{model() | input: [:text, :image]}
    body = Request.build(vision, %Context{messages: [result], tools: []})

    assert [%{"type" => "function_call_output", "call_id" => "call_1", "output" => parts}] =
             body["input"]

    assert [
             %{"type" => "input_text", "text" => "Read image file [image/png]"},
             %{"type" => "input_image", "detail" => "auto", "image_url" => url}
           ] = parts

    assert url == "data:image/png;base64,QUJD"

    # A text-only model gets the text output instead of the part list.
    text_only = %Model{model() | input: [:text]}
    body = Request.build(text_only, %Context{messages: [result], tools: []})

    assert [%{"output" => "Read image file [image/png]"}] = body["input"]
  end

  test "user images are omitted safely for text-only models" do
    message = %Message.User{
      content: [
        %Content.Text{text: "describe this"},
        %Content.Image{data: "QUJD", mime_type: "image/png"}
      ]
    }

    vision = %Model{model() | input: [:text, :image]}
    vision_body = Request.build(vision, %Context{messages: [message], tools: []})

    assert [
             %{
               "content" => [
                 %{"type" => "input_text", "text" => "describe this"},
                 %{"type" => "input_image", "image_url" => "data:image/png;base64,QUJD"}
               ]
             }
           ] = vision_body["input"]

    text_only = %Model{model() | input: [:text]}
    text_body = Request.build(text_only, %Context{messages: [message], tools: []})

    assert [%{"content" => [%{"type" => "input_text", "text" => "describe this"}]}] =
             text_body["input"]

    image_only = %Message.User{content: [%Content.Image{data: "QUJD", mime_type: "image/png"}]}
    placeholder = Request.build(text_only, %Context{messages: [image_only], tools: []})

    assert [%{"content" => [%{"type" => "input_text", "text" => "(see attached image)"}]}] =
             placeholder["input"]
  end

  test "unknown content blocks in a user message are dropped, not a crash" do
    message = %Message.User{
      content: [
        %Content.Text{text: "play this"},
        %UnknownBlock{data: "AAAA"}
      ]
    }

    body = Request.build(model(), %Context{messages: [message], tools: []})

    assert [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "play this"}]}] =
             body["input"]

    # A user message carrying ONLY unknown blocks yields an empty part list —
    # still a well-formed request, mirroring assistant_block/1's catch-all.
    only_unknown = %Message.User{content: [%UnknownBlock{data: "AAAA"}]}
    body = Request.build(model(), %Context{messages: [only_unknown], tools: []})
    assert [%{"role" => "user", "content" => []}] = body["input"]
  end

  test "includes service_tier only when set (the Fast-mode knob)" do
    ctx = %Context{system_prompt: nil, messages: [], tools: []}

    assert Request.build(model(), ctx, service_tier: "priority")["service_tier"] == "priority"
    refute Map.has_key?(Request.build(model(), ctx, []), "service_tier")
    refute Map.has_key?(Request.build(model(), ctx, service_tier: nil), "service_tier")
  end

  test "includes reasoning config when an effort is set" do
    context = %Context{messages: [Message.user("hi")], tools: []}
    body = Request.build(model(), context, reasoning_effort: "high")
    assert body["reasoning"] == %{"effort" => "high", "summary" => "auto"}
  end

  test "semantic projection omits volatile assistant replay ids and remains stable" do
    assistant = %Message.Assistant{content: Content.text("prior answer"), stop_reason: :stop}
    context = %Context{messages: [assistant], tools: []}

    assert [%{"id" => "msg_" <> _, "type" => "message"}] =
             Request.input_items(context.messages, model())

    assert [%{"type" => "message"} = semantic_message] =
             Request.input_items(context.messages, model(), assistant_replay_ids: :omit)

    refute Map.has_key?(semantic_message, "id")

    first = Request.semantic_projection(model(), context, session_id: "session")
    second = Request.semantic_projection(model(), context, session_id: "session")

    assert first == second
    assert Tokens.projection_digest(first) == Tokens.projection_digest(second)

    assert {:ok, Tokens.projection_digest(first)} ==
             Provider.context_fingerprint(model(), context, session_id: "session")
  end
end
