defmodule Catalyst.Session.StoreEncodeTest do
  use ExUnit.Case, async: true

  alias Catalyst.{Content, Message, Model, Usage}
  alias Catalyst.Session.Store

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
        cost: 0.5,
        context_digest: String.duplicate("a", 64)
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

  test "context model metadata round-trips independently from max_tokens" do
    model = %Model{
      id: "gpt-test",
      api: "openai-codex-responses",
      provider: "openai-codex",
      context_window: 272_000,
      max_context_window: 300_000,
      effective_context_window_percent: 95,
      auto_compact_token_limit: 240_000,
      context_window_source: :catalog,
      max_tokens: 128_000
    }

    encoded = Store.encode_model(model)

    assert encoded["contextWindow"] == 272_000
    assert encoded["maxContextWindow"] == 300_000
    assert encoded["effectiveContextWindowPercent"] == 95
    assert encoded["autoCompactTokenLimit"] == 240_000
    assert encoded["contextWindowSource"] == "catalog"
    assert encoded["maxTokens"] == 128_000
    assert {:ok, ^model} = Store.decode_model(encoded)
  end

  test "legacy usage without contextDigest remains valid and unanchored" do
    assistant = %Message.Assistant{usage: %Usage{total_tokens: 12}}

    encoded =
      assistant |> Store.encode() |> Map.update!("usage", &Map.delete(&1, "contextDigest"))

    assert {:ok, %Message.Assistant{usage: %Usage{total_tokens: 12, context_digest: nil}}} =
             Store.decode(encoded)
  end

  test "invalid persisted messages return tagged decode errors" do
    assert {:error, {:unknown_role, "martian"}} = Store.decode(%{"role" => "martian"})

    assert {:error, {:invalid_content_block, %{"type" => "future"}}} =
             Store.decode(%{"role" => "user", "content" => [%{"type" => "future"}]})

    assert {:error, {:invalid_message, :not_a_map}} = Store.decode(:not_a_map)
  end

  defp round_trip(message) do
    assert {:ok, decoded} = message |> Store.encode() |> Store.decode()
    decoded
  end
end
