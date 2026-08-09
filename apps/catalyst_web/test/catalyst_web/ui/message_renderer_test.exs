defmodule CatalystWeb.UI.MessageRendererTest do
  # async: false — registers into the global CatalystWeb.UI.Registry.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.{Content, Message}
  alias CatalystWeb.UI.{ImageStore, MessageRenderer, Registry}

  defmodule BrokenRenderer do
    use CatalystWeb, :html
    # Building this template succeeds; @missing_assign is only fetched (and
    # raises) when the Rendered's dynamics are evaluated — i.e. at diff time,
    # which is exactly what safe_render's forced evaluation must trap.
    def card(assigns), do: ~H|<div>BROKEN-CARD:{@missing_assign}</div>|
  end

  defp render_html(msg), do: rendered_to_string(MessageRenderer.render_message(%{msg: msg}))
  defp render_doc(msg), do: msg |> render_html() |> LazyHTML.from_fragment()

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

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

  # Quiet mode's CSS ([data-quiet] rules in app.css) targets these attributes.
  test "blocks carry stable data-block-kind attributes (quiet-mode contract)" do
    msg = %Message.Assistant{
      content: [
        %Content.Thinking{thinking: "pondering"},
        %Content.Text{text: "let me look"},
        %Content.ToolCall{id: "c1", name: "ls", arguments: %{}}
      ]
    }

    html = render_html(msg)
    assert html =~ ~s(data-block-kind="text")
    assert html =~ ~s(data-block-kind="thinking")
    assert html =~ ~s(data-block-kind="tool-call")
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

  test "protocol-relative links (//host) are not clickable; single-slash paths are" do
    msg = %Message.Assistant{content: Content.text("[spoof](//evil.example) [ok](/local/path)")}
    doc = render_doc(msg)

    anchors = LazyHTML.query(doc, "a")
    assert LazyHTML.attribute(anchors, "href") == ["/local/path"]
    assert LazyHTML.text(doc) =~ "spoof"
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

  test "a tool result renders image blocks with the stable block kind" do
    msg = %Message.ToolResult{
      tool_call_id: "c8",
      tool_name: "computer",
      content: [
        %Content.Text{text: "Screenshot of display 1"},
        %Content.Image{data: Base.encode64(<<1, 2, 3>>), mime_type: "image/png"}
      ]
    }

    html = render_html(msg)
    doc = LazyHTML.from_fragment(html)

    # data-block-kind is the quiet-mode CSS contract (app.css), like the
    # assistant block kinds asserted above.
    assert html =~ ~s(data-block-kind="tool-image")

    # Images are served out of line by digest (CatalystWeb.ImageController),
    # never inlined as data URIs — reconnects re-stream the whole transcript.
    [src] = doc |> LazyHTML.query("[data-block-kind=tool-image] img") |> LazyHTML.attribute("src")
    assert src == "/image/" <> sha256_hex(<<1, 2, 3>>)

    # The referenced bytes are actually servable.
    assert ImageStore.fetch(sha256_hex(<<1, 2, 3>>)) == {:ok, {"image/png", <<1, 2, 3>>}}

    # The text preview still renders alongside the image.
    assert html =~ "Screenshot of display 1"
  end

  test "a user message image is also referenced out of line" do
    msg =
      Message.user([
        %Content.Image{data: Base.encode64(<<9, 9, 9>>), mime_type: "image/png"},
        %Content.Text{text: "see attached"}
      ])

    doc = render_doc(msg)

    [src] = doc |> LazyHTML.query("img") |> LazyHTML.attribute("src")
    assert src == "/image/" <> sha256_hex(<<9, 9, 9>>)
    assert LazyHTML.text(doc) =~ "see attached"
  end

  test "an unservable image degrades to a src-less placeholder, not a crash" do
    msg = %Message.ToolResult{
      tool_call_id: "c3",
      tool_name: "computer",
      content: [%Content.Image{data: "%%%not-base64%%%", mime_type: "image/png"}]
    }

    html = render_html(msg)
    doc = LazyHTML.from_fragment(html)

    assert html =~ ~s(data-block-kind="tool-image")

    assert doc |> LazyHTML.query("[data-block-kind=tool-image] img") |> LazyHTML.attribute("src") ==
             []
  end

  test "a tool result without images renders no image container" do
    msg = %Message.ToolResult{
      tool_call_id: "c7",
      tool_name: "ls",
      content: Content.text("a.txt")
    }

    refute render_html(msg) =~ "tool-image"
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

  test "an extension renderer that raises at diff time falls back to built-in" do
    on_exit(fn -> Registry.unregister_owner("broken_renderer_test") end)

    Registry.register_renderer(
      :message,
      fn msg -> match?(%Message.ToolResult{tool_name: "broken-card"}, msg) end,
      &BrokenRenderer.card/1,
      owner: "broken_renderer_test"
    )

    msg = %Message.ToolResult{
      tool_call_id: "c9",
      tool_name: "broken-card",
      content: Content.text("still visible")
    }

    # The template raises only when its dynamics run (missing assign), so a
    # guard around the lazy build alone would let the diff engine crash the
    # LiveView. Forced evaluation falls back to the built-in tool card.
    html = render_html(msg)
    refute html =~ "BROKEN-CARD"
    assert html =~ ~s(data-message-role="tool-result")
    assert html =~ "still visible"
  end

  # AUDIT: every persisted screenshot is re-embedded as a full base64 data URI on
  # every render, and reattach streams the whole transcript. A routine
  # 100-screenshot session therefore needs 100+ MB of HTML just to reconnect.
  # A rendered screenshot needs a thumbnail or an out-of-line reference, not the
  # capture payload inlined once per reconnect.
  @tag :audit
  test "a rendered screenshot does not inline the whole capture payload" do
    # A downscaled 1366px PNG is ~0.5-1.5MB of base64; use a modest 512KB.
    payload = Base.encode64(:crypto.strong_rand_bytes(384 * 1024))

    msg = %Message.ToolResult{
      tool_call_id: "c1",
      tool_name: "computer",
      content: [
        Content.text("Screenshot of window 42."),
        %Content.Image{data: payload, mime_type: "image/png"}
      ],
      details: %{},
      is_error: false,
      timestamp: Message.now()
    }

    html = render_html(msg)

    assert html =~ ~s(data-block-kind="tool-image")

    assert byte_size(html) < div(byte_size(payload), 4),
           "the renderer inlined #{byte_size(html)} bytes for a #{byte_size(payload)}-byte " <>
             "capture; a 100-screenshot session cannot be reconnected"
  end
end
