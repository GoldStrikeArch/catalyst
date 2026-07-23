defmodule CatalystWeb.ShellLiveTest do
  # async: false — registers into the global CatalystWeb.UI.Registry.
  use CatalystWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Catalyst.Agent.Event
  alias Catalyst.LLM.Event, as: LLMEvent
  alias Catalyst.{Content, Message}
  alias Catalyst.Session.Server
  alias CatalystWeb.UI.Registry

  defmodule SettingsPage do
    use CatalystWeb, :html
    def render(assigns), do: ~H|<div>SETTINGS-PAGE-CONTENT</div>|
  end

  defmodule BrokenPage do
    use CatalystWeb, :html
    # Building this template succeeds; @missing_assign is only fetched (and
    # raises) when the Rendered's dynamics are evaluated — i.e. at diff time,
    # which is exactly what render_active_page's forced evaluation must trap.
    def render(assigns), do: ~H|<div>BROKEN-PAGE:{@missing_assign}</div>|
  end

  defmodule LsRenderer do
    use CatalystWeb, :html
    def card(assigns), do: ~H|<div>CUSTOM-LS-CARD:{@msg.tool_name}</div>|
  end

  test "a runtime-registered page renders via the catch-all route", %{conn: conn} do
    on_exit(fn -> Registry.unregister_owner("e5_page") end)

    Registry.register_page("settings", {SettingsPage, :render},
      owner: "e5_page",
      label: "Settings"
    )

    {:ok, view, _html} = live(conn, "/settings")
    assert has_element?(view, "#catalyst-shell", "SETTINGS-PAGE-CONTENT")
    assert has_element?(view, "#shell-page-nav", "Settings")
  end

  test "an extension page that raises at diff time falls back to chat", %{conn: conn} do
    on_exit(fn -> Registry.unregister_owner("e5_broken_page") end)

    Registry.register_page("broken", {BrokenPage, :render},
      owner: "e5_broken_page",
      label: "Broken"
    )

    # The template raises only when its dynamics run (missing assign), so a
    # guard around the lazy build alone would let the diff engine crash-loop
    # the LiveView. Forced evaluation renders the chat fallback instead.
    {:ok, view, _html} = live(conn, "/broken")
    refute has_element?(view, "#catalyst-shell", "BROKEN-PAGE")
    assert has_element?(view, "#chat-empty-state", "Ask Catalyst to inspect this project.")
    assert has_element?(view, "#chat-form")
  end

  test "a custom message renderer overrides the built-in tool card", %{conn: conn} do
    on_exit(fn -> Registry.unregister_owner("e5_render") end)

    Registry.register_renderer(
      :message,
      fn msg -> match?(%Message.ToolResult{tool_name: "ls"}, msg) end,
      &LsRenderer.card/1,
      owner: "e5_render"
    )

    {:ok, view, _html} = live(conn, ~p"/")

    submit_prompt(view, "list the files")

    assert has_element?(view, "#message-stream", "CUSTOM-LS-CARD:ls")
    refute has_element?(view, "#chat-empty-state")
  end

  test "the chat page is the default at /", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#shell-header")
    assert has_element?(view, "#chat-empty-state", "Ask Catalyst to inspect this project.")
  end

  test "the chat starts empty and renders messages through a LiveView stream", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#chat-empty-state", "Ask Catalyst to inspect this project.")
    assert has_element?(view, "#message-stream")
  end

  test "streaming pushes deltas to the client bubble, then the final message replaces it",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    id = session_id(view)

    send(
      view.pid,
      {:agent_event, id, %Event.MessageStart{message: %Message.Assistant{content: []}}}
    )

    assert has_element?(view, "#streaming-message")
    assert has_element?(view, "#streaming-message [data-stream=text]")
    assert has_element?(view, "#stream-dots", "Assistant is working")

    send(
      view.pid,
      {:agent_event, id, %Event.MessageUpdate{llm_event: %LLMEvent.ThinkingDelta{delta: "hmm…"}}}
    )

    send(
      view.pid,
      {:agent_event, id,
       %Event.MessageUpdate{llm_event: %LLMEvent.TextDelta{delta: "- partial `item`"}}}
    )

    # Each delta is push_event'd for the client-side append (the server render
    # itself stays at the seed — LiveView never repaints the ignored bubble).
    assert_push_event(view, "stream_delta", %{kind: "thinking", delta: "hmm…"})
    assert_push_event(view, "stream_delta", %{kind: "text", delta: "- partial `item`"})
    refute has_element?(view, "#catalyst-shell", "partial")

    final = %Message.Assistant{content: Content.text("- final `item`")}
    send(view.pid, {:agent_event, id, %Event.MessageEnd{message: final}})

    refute has_element?(view, "#streaming-message")
    assert has_element?(view, "#message-stream ul li")
    assert has_element?(view, "#message-stream code", "item")
    assert has_element?(view, "#message-stream", "final")
  end

  test "streaming commits stable markdown blocks progressively through the real renderer",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    id = session_id(view)

    send(
      view.pid,
      {:agent_event, id, %Event.MessageStart{message: %Message.Assistant{content: []}}}
    )

    deltas = [
      "# Ti",
      "tle\n",
      "\nintro para\n",
      "\n```elixir\ndef f, do: :ok\n",
      "```\n",
      "\nclosing thoughts"
    ]

    for d <- deltas do
      send(
        view.pid,
        {:agent_event, id, %Event.MessageUpdate{llm_event: %LLMEvent.TextDelta{delta: d}}}
      )
    end

    # The heading, paragraph, and (fence-closed) code block stabilized and
    # rendered through MessageRenderer while the message is still streaming.
    assert has_element?(view, "#stream-blocks", "Title")
    assert has_element?(view, "#stream-blocks p", "intro para")
    assert has_element?(view, "#stream-blocks pre code[data-lang=elixir]")
    assert has_element?(view, "#stream-blocks", "def f, do: :ok")

    # Each commit trimmed the client tail to the open block's source.
    assert_push_event(view, "stream_tail", %{text: _})

    # The raw open tail ("closing thoughts", no newline yet) is NOT committed.
    refute has_element?(view, "#stream-blocks", "closing thoughts")

    full = "# Title\n\nintro para\n\n```elixir\ndef f, do: :ok\n```\n\nclosing thoughts"
    final = %Message.Assistant{content: Content.text(full)}
    send(view.pid, {:agent_event, id, %Event.MessageEnd{message: final}})

    # The bubble is gone; the final message shows the same blocks.
    refute has_element?(view, "#streaming-message")
    assert has_element?(view, "#message-stream pre code[data-lang=elixir]")
    assert has_element?(view, "#message-stream", "closing thoughts")
  end

  defmodule SlowStreamProvider do
    @moduledoc """
    Streams one text delta, then blocks until the test says finish — so the
    session server genuinely holds an in-flight `streaming_message` while the
    test exercises the late-joiner replay path.
    """
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(model, _context, _opts, sink) do
      sink.(%Catalyst.LLM.Event.TextDelta{delta: "already streamed"})
      test = Application.fetch_env!(:catalyst_web, :slow_provider_test)
      send(test, {:slow_provider, self()})

      receive do
        :finish -> :ok
      end

      {:ok,
       %Message.Assistant{
         content: Content.text("done"),
         model: model && model.id,
         stop_reason: :stop,
         timestamp: Message.now()
       }}
    end
  end

  test "a mid-stream replay seeds the bubble with the accumulated partial text",
       %{conn: conn} do
    {:ok, previous_provider} = Catalyst.LLM.Registry.fetch_config("openai-codex-responses")
    :ok = Catalyst.LLM.Registry.register_provider("openai-codex-responses", SlowStreamProvider)
    Application.put_env(:catalyst_web, :slow_provider_test, self())

    on_exit(fn ->
      :ok =
        Catalyst.LLM.Registry.register_provider(
          "openai-codex-responses",
          previous_provider
        )

      Application.delete_env(:catalyst_web, :slow_provider_test)
    end)

    {:ok, view, _html} = live(conn, ~p"/")
    id = session_id(view)
    [{session_pid, _}] = Elixir.Registry.lookup(Catalyst.Session.Registry, id)

    view |> form("#chat-form", %{"message" => "stream please"}) |> render_submit()
    assert_receive {:slow_provider, provider_pid}, 5_000

    # Wait for the delta cast to fold into the server's streaming state.
    wait_until(fn ->
      Server.state(session_pid).streaming_message != nil
    end)

    # Patch away and back: the chat replays from the snapshot — the bubble's
    # server-rendered seed must carry the partial text a late joiner missed.
    view |> element("a", "Extensions") |> render_click()
    view |> element("a", "Chat") |> render_click()

    assert has_element?(view, "#streaming-message")
    assert has_element?(view, "#streaming-message", "already streamed")

    send(provider_pid, :finish)

    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 5_000
  end

  test "a replayed MessageEnd after a page round-trip is deduped, new ones are not",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    id = session_id(view)
    submit_prompt(view, "run ls for me")

    # Page away and back arms the replayed_tail dedup window from the snapshot.
    view |> element("a", "Extensions") |> render_click()
    view |> element("a", "Chat") |> render_click()

    [{session_pid, _}] = Elixir.Registry.lookup(Catalyst.Session.Registry, id)
    last = Catalyst.Session.Server.state(session_pid).messages |> List.last()
    # A needle that survives markdown rendering (no backticks/formatting).
    needle = "offline Demo provider"
    assert Catalyst.Content.text_of(last.content) =~ needle
    stream_html = fn -> view |> element("#message-stream") |> render() end
    count = fn html -> length(String.split(html, needle)) - 1 end

    before_count = count.(stream_html.())
    assert before_count >= 1

    # A duplicate broadcast (the reattach race) must NOT double-render...
    send(view.pid, {:agent_event, id, %Event.MessageEnd{message: last}})
    assert count.(stream_html.()) == before_count

    # ...while a genuinely new message still renders (the window closed).
    fresh = %Message.User{content: Content.text("brand new message")}
    send(view.pid, {:agent_event, id, %Event.MessageEnd{message: fresh}})
    assert has_element?(view, "#message-stream", "brand new message")
  end

  # 1x1 red-pixel PNG.
  @png_bytes Base.decode64!(
               "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
             )

  test "a pasted image is sent as an image content block and rendered in the bubble",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    id = session_id(view)
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    input =
      file_input(view, "#chat-form", :image, [
        %{name: "shot.png", content: @png_bytes, type: "image/png"}
      ])

    render_upload(input, "shot.png")

    view |> form("#chat-form", %{"message" => "what is in this screenshot?"}) |> render_submit()
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 5_000

    # The user bubble shows the attached thumbnail alongside the text.
    assert has_element?(view, ~s(#message-stream img[src^="data:image/png;base64,"]))
    assert has_element?(view, "#message-stream", "what is in this screenshot?")

    # And the session's transcript carries a real image content block.
    [{session_pid, _}] = Elixir.Registry.lookup(Catalyst.Session.Registry, id)
    user = Server.state(session_pid).messages |> Enum.find(&match?(%Message.User{}, &1))

    assert [%Catalyst.Content.Text{}, %Catalyst.Content.Image{} = img] = user.content
    assert img.mime_type == "image/png"
    assert Base.decode64!(img.data) == @png_bytes
  end

  test "tool execution indicators and results render immediately", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    id = session_id(view)

    send(
      view.pid,
      {:agent_event, id, %Event.ToolExecutionStart{call_id: "call-1", name: "grep", args: %{}}}
    )

    assert has_element?(view, "#tool-indicator-call-1", "running")
    assert has_element?(view, "#tool-indicator-call-1 code", "grep")

    # A streamed partial-output tail renders under the spinner.
    send(
      view.pid,
      {:agent_event, id,
       %Event.ToolExecutionUpdate{
         call_id: "call-1",
         name: "grep",
         args: %{},
         partial: %{output: "partial tail line"}
       }}
    )

    assert has_element?(view, "#tool-indicator-call-1 [data-tool-partial]", "partial tail line")

    result = %Message.ToolResult{
      tool_call_id: "call-1",
      tool_name: "grep",
      content: Content.text("found it")
    }

    send(view.pid, {:agent_event, id, %Event.MessageEnd{message: result}})

    assert has_element?(view, ~s(#message-stream [data-message-role="tool-result"]), "found it")

    send(view.pid, {:agent_event, id, %Event.ToolExecutionEnd{call_id: "call-1"}})

    refute has_element?(view, "#tool-indicator-call-1")
  end

  test "context status updates the header meter without adding a chat block", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    id = session_id(view)

    status = %Event.ContextStatus{
      used_tokens: 12_500,
      threshold: 20_000,
      threshold_source: {:application, :context_thresholds, "gpt-5.4"},
      anchored: true,
      estimate_source: :provider,
      context_digest: "context-digest"
    }

    send(view.pid, {:agent_event, id, status})

    assert has_element?(view, "#context-meter")
    assert has_element?(view, "#context-token-count", "12.5k / 20.0k")
    assert has_element?(view, "#context-estimate-state", "anchored")
    assert has_element?(view, "#context-threshold-source", "context_thresholds")
    assert has_element?(view, "#chat-empty-state")
    refute has_element?(view, "#message-stream > *")

    send(view.pid, {:agent_event, id, %{status | anchored: false, estimate_source: :coarse}})
    assert has_element?(view, "#context-estimate-state", "estimated")
  end

  test "context compaction resets and re-streams the authoritative replacement", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    id = session_id(view)

    old_user = %Message.User{content: Content.text("OLD-CONTEXT-USER")}
    old_assistant = %Message.Assistant{content: Content.text("OLD-CONTEXT-ASSISTANT")}

    send(view.pid, {:agent_event, id, %Event.MessageEnd{message: old_user}})
    send(view.pid, {:agent_event, id, %Event.MessageEnd{message: old_assistant}})

    assert has_element?(view, "#message-stream", "OLD-CONTEXT-USER")
    assert has_element?(view, "#message-stream", "OLD-CONTEXT-ASSISTANT")

    replacement = [
      %Message.User{content: Content.text("COMPACTED-SUMMARY")},
      %Message.Assistant{content: Content.text("KEPT-AFTER-COMPACTION")}
    ]

    send(
      view.pid,
      {:agent_event, id,
       %Event.ContextCompacted{
         replacement: replacement,
         summary: hd(replacement),
         replaced_count: 2,
         tokens_before: 1_000,
         tokens_after: 400,
         policy: Catalyst.Context.Window
       }}
    )

    refute has_element?(view, "#message-stream", "OLD-CONTEXT-USER")
    refute has_element?(view, "#message-stream", "OLD-CONTEXT-ASSISTANT")
    assert has_element?(view, "#message-stream", "COMPACTED-SUMMARY")
    assert has_element?(view, "#message-stream", "KEPT-AFTER-COMPACTION")
    refute has_element?(view, "#chat-empty-state")
  end

  test "a never-run session exposes a supervised read-only prompt preview", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert wait_until(fn -> has_element?(view, "#run-diagnostics") end)
    assert has_element?(view, "#run-diagnostics-toggle[aria-expanded=false]")
    refute has_element?(view, "#resolved-prompt-text")

    view |> element("#run-diagnostics-toggle") |> render_click()

    assert has_element?(view, "#run-diagnostics-toggle[aria-expanded=true]")
    assert has_element?(view, "#run-diagnostics-panel")
    assert has_element?(view, "#prompt-digest")
    assert has_element?(view, "#prompt-provenance li")
    assert has_element?(view, "#resolved-prompt-text[readonly]")
  end

  test "a completed run exposes model, workflow, and resolved prompt metadata", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    submit_prompt(view, "show run diagnostics")
    assert wait_until(fn -> has_element?(view, "#run-diagnostics") end)

    view |> element("#run-diagnostics-toggle") |> render_click()

    assert has_element?(view, "#model-context-diagnostics")
    assert has_element?(view, "#workflow-diagnostics")
    assert has_element?(view, "#prompt-diagnostics", "Resolved run prompt")
  end

  test "an event tagged with another session's id is dropped, not rendered", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    leaked = %Message.Assistant{content: Content.text("LEAKED-FROM-OTHER-SESSION")}

    send(
      view.pid,
      {:agent_event, "not-" <> session_id(view), %Event.MessageEnd{message: leaked}}
    )

    refute has_element?(view, "#catalyst-shell", "LEAKED-FROM-OTHER-SESSION")
    # The transcript is untouched — the empty state is still up.
    assert has_element?(view, "#chat-empty-state")
  end

  test "the web self-modification tools are registered into the core tool set" do
    assert Catalyst.Extensions.fetch("rebuild_assets") == {:ok, CatalystWeb.Tools.RebuildAssets}
    assert Catalyst.Extensions.fetch("reload_ui") == {:ok, CatalystWeb.Tools.ReloadUi}
  end

  test "an asset reload broadcast triggers a full page reload in connected views", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    CatalystWeb.Assets.reload()
    assert_redirect(view, "/")
  end

  test "an asset reload keeps users on their current (non-chat) page", %{conn: conn} do
    on_exit(fn -> Registry.unregister_owner("e5_reload_page") end)

    Registry.register_page("settings", {SettingsPage, :render},
      owner: "e5_reload_page",
      label: "Settings"
    )

    {:ok, view, _html} = live(conn, "/settings")
    CatalystWeb.Assets.reload()
    assert_redirect(view, "/settings")
  end

  test "a bare /cd flashes a usage hint instead of prompting the model", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("#chat-form", %{"message" => "/cd "}) |> render_submit()

    assert has_element?(view, "#flash-error", "usage: /cd")
    # Nothing was sent to the agent.
    assert has_element?(view, "#chat-empty-state")
  end

  test "an unknown /command flashes the known command list instead of prompting", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("#chat-form", %{"message" => "/nope now"}) |> render_submit()

    assert has_element?(view, "#flash-error", "unknown command /nope")
    assert has_element?(view, "#flash-error", "/cd")
    assert has_element?(view, "#chat-empty-state")
  end

  test "a runtime-registered command dispatches from the chat input", %{conn: conn} do
    parent = self()

    CatalystWeb.UI.Registry.register_command("ping_test",
      owner: "cmd_test",
      handler: fn arg, socket ->
        send(parent, {:command_ran, arg})
        Phoenix.LiveView.put_flash(socket, :info, "pong #{arg}")
      end
    )

    on_exit(fn -> CatalystWeb.UI.Registry.unregister_owner("cmd_test") end)

    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("#chat-form", %{"message" => "/ping_test hello"}) |> render_submit()

    assert_receive {:command_ran, "hello"}
    assert has_element?(view, "#flash-info", "pong hello")
    assert has_element?(view, "#chat-empty-state")
  end

  test "/cd relative paths resolve from the active session cwd", %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "catalyst_cd_#{System.unique_integer([:positive])}")
    parent = Path.join(root, "parent")
    child = Path.join(parent, "child")

    File.mkdir_p!(child)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("#chat-form", %{"message" => "/cd #{parent}"}) |> render_submit()
    assert has_element?(view, "#chat-empty-state", parent)

    view |> form("#chat-form", %{"message" => "/cd child"}) |> render_submit()

    assert has_element?(view, "#chat-empty-state", child)
    refute has_element?(view, "#flash-error", "Not a directory")
  end
end
