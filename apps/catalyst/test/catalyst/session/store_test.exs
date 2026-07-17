defmodule Catalyst.Session.StoreTest do
  use ExUnit.Case, async: true

  alias Catalyst.{Content, Message, Usage}
  alias Catalyst.Session.Store

  test "messages round-trip through JSONL" do
    store = Store.new("/tmp/some/project")
    on_exit(fn -> File.rm_rf!(store.path) end)

    messages = [
      Message.user("hello"),
      %Message.Assistant{
        content: [
          %Content.Text{text: "let me look"},
          %Content.ToolCall{id: "call_1", name: "read", arguments: %{"path" => "x"}}
        ],
        provider: "faux",
        api: "faux",
        model: "faux-1",
        usage: %Usage{},
        stop_reason: :tool_use,
        timestamp: 123
      },
      %Message.ToolResult{
        tool_call_id: "call_1",
        tool_name: "read",
        content: [%Content.Text{text: "file body"}],
        details: %{"path" => "x"},
        is_error: false,
        timestamp: 124
      }
    ]

    Enum.each(messages, &Store.append_message(store, &1))
    loaded = Store.load(store.path)

    assert length(loaded) == 3
    assert [%Message.User{}, %Message.Assistant{} = a, %Message.ToolResult{} = tr] = loaded

    assert Content.text_of(a.content) == "let me look"
    assert a.stop_reason == :tool_use
    [_text, tool_call] = a.content
    assert %Content.ToolCall{name: "read", arguments: %{"path" => "x"}} = tool_call

    assert tr.tool_name == "read"
    assert Content.text_of(tr.content) == "file body"
  end

  test "header line is not decoded as a message" do
    store = Store.new("/tmp/proj2")
    on_exit(fn -> File.rm_rf!(store.path) end)
    assert Store.load(store.path) == []
  end
end
