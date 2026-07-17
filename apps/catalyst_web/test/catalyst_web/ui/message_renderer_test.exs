defmodule CatalystWeb.UI.MessageRendererTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Catalyst.{Content, Message}
  alias CatalystWeb.UI.MessageRenderer

  defp render_html(msg), do: rendered_to_string(MessageRenderer.render_message(%{msg: msg}))
  defp render_doc(msg), do: msg |> render_html() |> LazyHTML.from_fragment()

  defp count(doc, selector) do
    doc
    |> LazyHTML.query(selector)
    |> LazyHTML.to_tree()
    |> length()
  end

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

  test "assistant text renders common markdown structure" do
    msg = %Message.Assistant{
      content:
        Content.text("""
        Key behavior:

        - Builds a registry index from `config.tools`
        - Uses **parallel** execution

        Flow:

        1. `run_batch/3`
        2. `run_one/4`
        """)
    }

    doc = render_doc(msg)

    assert count(doc, "ul li") == 2
    assert count(doc, "ol li") == 2
    assert LazyHTML.query(doc, "code") |> LazyHTML.text() =~ "config.tools"
    assert LazyHTML.query(doc, "strong") |> LazyHTML.text() =~ "parallel"
  end

  test "assistant text renders fenced code without executing embedded html" do
    msg = %Message.Assistant{
      content:
        Content.text("""
        ```elixir
        def run, do: :ok
        ```

        <script>alert("x")</script>
        """)
    }

    doc = render_doc(msg)

    assert LazyHTML.query(doc, "pre code") |> LazyHTML.text() =~ "def run, do: :ok"
    assert LazyHTML.query(doc, "script") |> LazyHTML.to_tree() == []
    assert LazyHTML.text(doc) =~ "alert(\"x\")"
  end

  test "unsafe markdown links render as text rather than clickable anchors" do
    msg = %Message.Assistant{content: Content.text("[click me](javascript:alert(1))")}
    doc = render_doc(msg)

    assert LazyHTML.query(doc, "a") |> LazyHTML.to_tree() == []
    assert LazyHTML.text(doc) =~ "click me"
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
