defmodule Catalyst.LLM.OpenAICodex.StreamParserTest do
  use ExUnit.Case, async: true

  alias Catalyst.{Content, Message, Model}
  alias Catalyst.LLM.Event
  alias Catalyst.LLM.OpenAICodex.StreamParser

  defp model, do: %Model{id: "gpt-5.4", api: "openai-codex-responses", provider: "openai-codex"}

  defp run(events) do
    sink = fn ev -> send(self(), {:ev, ev}) end

    parser =
      Enum.reduce(events, StreamParser.new(), fn e, p -> StreamParser.handle(p, e, sink) end)

    StreamParser.finalize(parser, model())
  end

  test "assembles reasoning + a tool call into a tool_use assistant" do
    events = [
      %{"type" => "response.created", "response" => %{"id" => "resp_1"}},
      %{
        "type" => "response.output_item.added",
        "item" => %{"type" => "reasoning", "id" => "rs_1"}
      },
      %{"type" => "response.reasoning_text.delta", "delta" => "let me search"},
      %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "reasoning",
          "id" => "rs_1",
          "summary" => [%{"text" => "search for TODO"}],
          "encrypted_content" => "ENC"
        }
      },
      %{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => "call_1",
          "name" => "grep",
          "arguments" => ""
        }
      },
      %{"type" => "response.function_call_arguments.delta", "delta" => "{\"pattern\":"},
      %{"type" => "response.function_call_arguments.delta", "delta" => "\"TODO\"}"},
      %{
        "type" => "response.function_call_arguments.done",
        "arguments" => "{\"pattern\":\"TODO\"}"
      },
      %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => "call_1",
          "name" => "grep",
          "arguments" => "{\"pattern\":\"TODO\"}"
        }
      },
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_1",
          "status" => "completed",
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 5,
            "total_tokens" => 15,
            "input_tokens_details" => %{"cached_tokens" => 2}
          }
        }
      }
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

    assert {:ok, %{"encrypted_content" => "ENC", "type" => "reasoning"}} =
             Jason.decode(thinking.signature)

    # tool-call id is "<call_id>|<item_id>"
    assert tool.id == "call_1|fc_1"
    assert tool.name == "grep"
    assert tool.arguments == %{"pattern" => "TODO"}

    assert_received {:ev, %Event.ToolCallStart{id: "call_1|fc_1", name: "grep"}}
    assert_received {:ev, %Event.ToolCallEnd{arguments: %{"pattern" => "TODO"}}}
  end

  test "assembles a plain text turn" do
    events = [
      %{
        "type" => "response.output_item.added",
        "item" => %{"type" => "message", "id" => "msg_1"}
      },
      %{"type" => "response.output_text.delta", "delta" => "Hello "},
      %{"type" => "response.output_text.delta", "delta" => "world"},
      %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "message",
          "id" => "msg_1",
          "content" => [%{"type" => "output_text", "text" => "Hello world"}]
        }
      },
      %{"type" => "response.completed", "response" => %{"id" => "r", "status" => "completed"}}
    ]

    assistant = run(events)
    assert assistant.stop_reason == :stop
    assert Content.text_of(assistant.content) == "Hello world"
    assert_received {:ev, %Event.TextDelta{delta: "Hello "}}
  end

  test "the output_item.done payload is authoritative over accumulated deltas" do
    # Simulate a DROPPED delta frame: only "hel" arrived as a delta, but the
    # done item carries the complete text — the complete text must win.
    events = [
      %{
        "type" => "response.output_item.added",
        "item" => %{"type" => "message", "id" => "m1"}
      },
      %{"type" => "response.output_text.delta", "delta" => "hel"},
      %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "message",
          "id" => "m1",
          "content" => [%{"type" => "output_text", "text" => "hello world"}]
        }
      },
      %{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => "call_1",
          "name" => "grep",
          "arguments" => ""
        }
      },
      # Dropped arguments.delta: the accumulated partial is invalid JSON.
      %{"type" => "response.function_call_arguments.delta", "delta" => "{\"patt"},
      %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => "call_1",
          "name" => "grep",
          "arguments" => "{\"pattern\":\"TODO\"}"
        }
      },
      %{
        "type" => "response.completed",
        "response" => %{"id" => "r1", "status" => "completed"}
      }
    ]

    assistant = run(events)

    assert [%Content.Text{text: "hello world"}, %Content.ToolCall{arguments: args}] =
             assistant.content

    assert args == %{"pattern" => "TODO"}
  end

  test "surfaces a failed response as an error assistant" do
    events = [
      %{
        "type" => "response.failed",
        "response" => %{"error" => %{"code" => "rate_limit", "message" => "slow down"}}
      }
    ]

    assistant = run(events)
    assert assistant.stop_reason == :error
    assert assistant.error_message =~ "rate_limit"
    assert %Message.Assistant{} = assistant
  end

  test "every terminal event, including legacy done, completes parser normalization" do
    events = [
      %{
        "type" => "response.completed",
        "response" => %{"id" => "completed", "status" => "completed"}
      },
      %{"type" => "response.done", "response" => %{"id" => "done", "status" => "completed"}},
      %{
        "type" => "response.incomplete",
        "response" => %{
          "id" => "incomplete",
          "incomplete_details" => %{"reason" => "max_output_tokens"}
        }
      },
      %{
        "type" => "response.failed",
        "response" => %{"id" => "failed", "error" => %{"message" => "failed"}}
      },
      %{"type" => "response.cancelled", "response" => %{"id" => "cancelled"}},
      %{"type" => "error", "message" => "failed"}
    ]

    for event <- events do
      parser = StreamParser.handle(StreamParser.new(), event, fn _event -> :ok end)
      assert parser.done, "expected #{event["type"]} to complete the parser"
    end
  end

  test "a stream that drops mid-text keeps the partial text and reports an error" do
    events = [
      %{"type" => "response.output_item.added", "item" => %{"type" => "message", "id" => "m"}},
      %{"type" => "response.output_text.delta", "delta" => "Hello wo"}
      # connection drops: no output_item.done, no response.completed
    ]

    assistant = run(events)
    assert assistant.stop_reason == :error
    assert assistant.error_message =~ "ended before completion"
    assert Enum.any?(assistant.content, &match?(%Content.Text{text: "Hello wo"}, &1))
  end

  test "a stream that drops mid-reasoning keeps the text but emits NO signature" do
    events = [
      %{
        "type" => "response.output_item.added",
        "item" => %{"type" => "reasoning", "id" => "rs_1"}
      },
      %{"type" => "response.reasoning_text.delta", "delta" => "thinking ab"}
      # connection drops: no output_item.done (so no encrypted_content)
    ]

    assistant = run(events)
    assert assistant.stop_reason == :error

    # The partial item lacks encrypted_content; replaying it next turn risks a
    # 400, so the signature must be nil (Request skips nil-signature thinking).
    assert [%Content.Thinking{thinking: "thinking ab", signature: nil}, %Content.Text{}] =
             assistant.content

    assert_received {:ev, %Event.ThinkingDelta{delta: "thinking ab"}}
  end

  test "a stream that drops mid-tool-call discards the partial call" do
    events = [
      %{
        "type" => "response.output_item.added",
        "item" => %{"type" => "function_call", "id" => "fc", "call_id" => "c", "name" => "bash"}
      },
      %{"type" => "response.function_call_arguments.delta", "delta" => "{\"comm"}
    ]

    assistant = run(events)
    assert assistant.stop_reason == :error
    assert assistant.error_message =~ "discarded"
    refute Enum.any?(assistant.content, &match?(%Content.ToolCall{}, &1))
  end

  test "response.incomplete maps to :length and keeps usage" do
    events = [
      %{"type" => "response.output_item.added", "item" => %{"type" => "message", "id" => "m"}},
      %{"type" => "response.output_text.delta", "delta" => "partial"},
      %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "message",
          "id" => "m",
          "content" => [%{"type" => "output_text", "text" => "partial"}]
        }
      },
      %{
        "type" => "response.incomplete",
        "response" => %{
          "id" => "r",
          "incomplete_details" => %{"reason" => "max_output_tokens"},
          "usage" => %{"input_tokens" => 7, "output_tokens" => 3, "total_tokens" => 10}
        }
      }
    ]

    assistant = run(events)
    assert assistant.stop_reason == :length
    assert assistant.error_message =~ "max_output_tokens"
    assert assistant.usage.output == 3
  end

  # The websocket error frame nests code/message under "error" (the shape the
  # backend sends for a 400 on a replayed transcript); it used to finalize as
  # the blank "Error : ".
  test "a websocket-shaped error event surfaces the nested message" do
    events = [
      %{
        "type" => "error",
        "status" => 400,
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "Unknown parameter: 'input[1].output_index'."
        }
      }
    ]

    assistant = run(events)
    assert assistant.stop_reason == :error
    assert assistant.error_message =~ "invalid_request_error"
    assert assistant.error_message =~ "Unknown parameter"
    assert assistant.error_message =~ "400"
  end

  test "an unrecognized error event shape never finalizes blank" do
    assistant = run([%{"type" => "error"}])
    assert assistant.stop_reason == :error
    assert assistant.error_message =~ ~s({"type":"error"})
  end

  test "a late response.completed does not mask a prior error event" do
    events = [
      %{"type" => "error", "code" => "boom", "message" => "exploded"},
      %{"type" => "response.completed", "response" => %{"id" => "r", "status" => "completed"}}
    ]

    assistant = run(events)
    assert assistant.stop_reason == :error
    assert assistant.error_message =~ "boom"
  end

  test "malformed or non-object tool arguments finalize as errors without executable calls" do
    for bad_json <- ["{not-json", "[]"] do
      events = [
        %{
          "type" => "response.output_item.added",
          "output_index" => 0,
          "item" => %{
            "type" => "function_call",
            "id" => "fc_bad",
            "call_id" => "call_bad",
            "name" => "bash"
          }
        },
        %{
          "type" => "response.output_item.done",
          "output_index" => 0,
          "item" => %{
            "type" => "function_call",
            "id" => "fc_bad",
            "call_id" => "call_bad",
            "name" => "bash",
            "arguments" => bad_json
          }
        },
        %{
          "type" => "response.completed",
          "response" => %{"id" => "bad", "status" => "completed"}
        }
      ]

      assistant = run(events)

      assert assistant.stop_reason == :error
      assert assistant.error_message =~ "invalid tool arguments"
      refute Enum.any?(assistant.content, &match?(%Content.ToolCall{}, &1))
      refute_received {:ev, %Event.ToolCallEnd{id: "call_bad|fc_bad"}}
    end
  end

  test "interleaved parallel output items retain their own arguments and output order" do
    events = [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_read",
          "call_id" => "call_read",
          "name" => "read"
        }
      },
      %{
        "type" => "response.output_item.added",
        "output_index" => 1,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_grep",
          "call_id" => "call_grep",
          "name" => "grep"
        }
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "fc_read",
        "output_index" => 0,
        "delta" => "{\"path\":\"README.md\"}"
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "output_index" => 1,
        "delta" => "{\"pattern\":\"TODO\"}"
      },
      %{
        "type" => "response.output_item.done",
        "output_index" => 1,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_grep",
          "call_id" => "call_grep",
          "name" => "grep"
        }
      },
      %{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_read",
          "call_id" => "call_read",
          "name" => "read"
        }
      },
      %{
        "type" => "response.completed",
        "response" => %{"id" => "parallel", "status" => "completed"}
      }
    ]

    assistant = run(events)

    assert assistant.stop_reason == :tool_use

    assert [
             %Content.ToolCall{name: "read", arguments: %{"path" => "README.md"}},
             %Content.ToolCall{name: "grep", arguments: %{"pattern" => "TODO"}}
           ] = assistant.content
  end

  test "cancelled and incomplete terminals preserve their reason while discarding a partial call" do
    prefix = [
      %{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "id" => "fc_partial",
          "call_id" => "call_partial",
          "name" => "bash"
        }
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "fc_partial",
        "delta" => "{\"command\":"
      }
    ]

    cancelled =
      run(
        prefix ++
          [
            %{
              "type" => "response.completed",
              "response" => %{"id" => "cancelled", "status" => "cancelled"}
            }
          ]
      )

    incomplete =
      run(
        prefix ++
          [
            %{
              "type" => "response.incomplete",
              "response" => %{
                "id" => "incomplete",
                "incomplete_details" => %{"reason" => "max_output_tokens"}
              }
            }
          ]
      )

    assert cancelled.stop_reason == :aborted
    assert incomplete.stop_reason == :length
    refute Enum.any?(cancelled.content, &match?(%Content.ToolCall{}, &1))
    refute Enum.any?(incomplete.content, &match?(%Content.ToolCall{}, &1))
  end
end
