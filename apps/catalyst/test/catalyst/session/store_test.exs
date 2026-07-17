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
        usage: %Usage{input: 8, output: 5, cache_read: 2, total_tokens: 15, cost: 0.01},
        stop_reason: :tool_use,
        response_id: "resp_1",
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
    assert a.usage == %Usage{input: 8, output: 5, cache_read: 2, total_tokens: 15, cost: 0.01}
    assert a.response_id == "resp_1"
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

  test "reopening an existing session file preserves its transcript" do
    id = "resume_#{System.unique_integer([:positive])}"
    store = Store.new("/tmp/proj3", id: id)
    on_exit(fn -> File.rm_rf!(store.path) end)

    Store.append_message(store, Message.user("hello"))

    # Same id again (what a crash-restarted Session.Server does) must not truncate.
    reopened = Store.new("/tmp/proj3", id: id)
    assert reopened.path == store.path
    assert [%Message.User{}] = Store.load(reopened.path)
  end

  test "a reset marker clears everything before it on load" do
    store = Store.new("/tmp/proj_reset")
    on_exit(fn -> File.rm_rf!(store.path) end)

    Store.append_message(store, Message.user("old one"))
    Store.append_message(store, Message.user("old two"))
    Store.append_reset(store)
    Store.append_message(store, Message.user("fresh"))

    assert [%Message.User{} = m] = Store.load(store.path)
    assert Content.text_of(m.content) == "fresh"

    # A trailing reset leaves the session empty.
    Store.append_reset(store)
    assert Store.load(store.path) == []
  end

  test "load skips corrupt or unknown lines instead of crashing" do
    store = Store.new("/tmp/proj4")
    on_exit(fn -> File.rm_rf!(store.path) end)

    Store.append_message(store, Message.user("kept"))
    File.write!(store.path, "not json at all\n", [:append])
    File.write!(store.path, ~s({"type":"message","message":{"role":"martian"}}\n), [:append])

    File.write!(
      store.path,
      ~s({"type":"message","message":{"role":"assistant","stopReason":"new_unknown_reason"}}\n),
      [:append]
    )

    loaded = Store.load(store.path)
    assert [%Message.User{}, %Message.Assistant{stop_reason: :stop}] = loaded
  end
end
