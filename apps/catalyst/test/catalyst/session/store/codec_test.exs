defmodule Catalyst.Session.Store.CodecTest do
  use ExUnit.Case, async: true

  alias Catalyst.{Content, Message, Usage}
  alias Catalyst.Session.Store
  alias Catalyst.Session.Store.Codec

  test "user messages round-trip" do
    message = %Message.User{
      content: [
        %Content.Text{text: "hello"},
        %Content.Image{data: "aW1hZ2U=", mime_type: "image/png"}
      ],
      timestamp: 101
    }

    assert round_trip(message) == message
  end

  test "assistant messages round-trip" do
    message = %Message.Assistant{
      content: [
        %Content.Thinking{thinking: "inspect", signature: "sig", redacted: true},
        %Content.Text{text: "done"},
        %Content.ToolCall{id: "call_1", name: "read", arguments: %{"path" => "x"}}
      ],
      api: "responses",
      provider: "openai",
      model: "gpt-test",
      usage: %Usage{
        input: 11,
        output: 7,
        cache_read: 3,
        cache_write: 2,
        total_tokens: 23,
        cost: 0.5
      },
      stop_reason: :tool_use,
      error_message: nil,
      response_id: "resp_1",
      timestamp: 102
    }

    assert round_trip(message) == message
  end

  test "tool-result messages round-trip" do
    message = %Message.ToolResult{
      tool_call_id: "call_1",
      tool_name: "read",
      content: [%Content.Text{text: "file body"}],
      details: %{"path" => "x", "lines" => 4},
      is_error: true,
      timestamp: 103
    }

    assert round_trip(message) == message
  end

  test "Store encode and decode remain compatibility shims" do
    message = %Message.User{content: [%Content.Text{text: "shim"}], timestamp: 104}

    assert Store.encode(message) == Codec.encode(message)
    assert message |> Store.encode() |> Store.decode() == message
  end

  defp round_trip(message), do: message |> Codec.encode() |> Codec.decode()
end
