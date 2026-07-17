defmodule CatalystWeb.UI.MessageRendererTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Catalyst.{Content, Message}
  alias CatalystWeb.UI.MessageRenderer

  defp render_html(msg), do: rendered_to_string(MessageRenderer.render_message(%{msg: msg}))

  test "a user message renders its text on the right" do
    html = render_html(Message.user("hello there"))
    assert html =~ "hello there"
    assert html =~ ~s(data-message-role="user")
  end

  test "an assistant message renders text and tool-call blocks" do
    msg = %Message.Assistant{
      content: [
        %Content.Text{text: "let me look"},
        %Content.ToolCall{id: "c1", name: "ls", arguments: %{"path" => "."}}
      ]
    }

    html = render_html(msg)
    assert html =~ ~s(data-message-role="assistant")
    assert html =~ "let me look"
    assert html =~ "ls("
  end

  test "a thinking block renders inside a collapsible disclosure" do
    msg = %Message.Assistant{content: [%Content.Thinking{thinking: "pondering"}]}
    html = render_html(msg)
    assert html =~ "<details"
    assert html =~ "pondering"
  end

  test "a successful tool result shows the tool name and output" do
    msg = %Message.ToolResult{
      tool_call_id: "c1",
      tool_name: "ls",
      content: Content.text("a.txt\nb.txt")
    }

    html = render_html(msg)
    assert html =~ ~s(data-message-role="tool-result")
    assert html =~ ~s(data-tool-error="false")
    assert html =~ "ls"
    assert html =~ "a.txt"
  end

  test "an error tool result is flagged" do
    msg = %Message.ToolResult{
      tool_call_id: "c2",
      tool_name: "bash",
      content: Content.text("boom"),
      is_error: true
    }

    html = render_html(msg)
    assert html =~ ~s(data-tool-error="true")
    assert html =~ "bash"
    assert html =~ "boom"
    assert html =~ "error"
  end
end
