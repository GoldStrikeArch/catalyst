defmodule Catalyst.LLM.OpenAICodex.ProviderTest do
  use ExUnit.Case, async: false

  alias Catalyst.LLM.Context
  alias Catalyst.LLM.OpenAICodex
  alias Catalyst.Test.Codex
  alias Catalyst.{Content, Message}

  test "returns an error assistant (never raises) when not authenticated" do
    model = OpenAICodex.model("gpt-5.4")
    context = Codex.context()

    assert {:ok, assistant} = OpenAICodex.Provider.stream(model, context, [], fn _ -> :ok end)
    assert assistant.stop_reason == :error
    assert assistant.error_message =~ "not authenticated"
    assert assistant.api == "openai-codex-responses"
  end

  test "the api is registered to the Codex provider" do
    assert {:ok, OpenAICodex.Provider} = Catalyst.LLM.Registry.fetch("openai-codex-responses")
  end

  test "a token without a ChatGPT account id fails loudly instead of 401-looping" do
    Codex.put_token!(%{account_id: nil})

    model = OpenAICodex.model("gpt-5.4")
    context = Codex.context()

    assert {:ok, assistant} = OpenAICodex.Provider.stream(model, context, [], fn _ -> :ok end)
    assert assistant.stop_reason == :error
    assert assistant.error_message =~ "account id"
    assert assistant.error_message =~ "sign in again"
  end

  test "a 429 usage-limit response surfaces as a friendly message, not raw JSON" do
    Codex.put_token!()

    resets_at = div(System.system_time(:millisecond), 1000) + 30 * 60

    port = Codex.start_server!({Codex.UsageLimitCodex, %{resets_at: resets_at}})

    model = Codex.model(port)
    context = Codex.context()

    assert {:ok, assistant} =
             OpenAICodex.Provider.stream(model, context, [transport: :sse], fn _ -> :ok end)

    assert assistant.stop_reason == :error
    assert assistant.error_message =~ "You have hit your ChatGPT usage limit (plus plan)."
    assert assistant.error_message =~ ~r/Try again in ~(29|30) min\./
    refute assistant.error_message =~ "usage_limit_reached"
  end

  test "a 401 before any SSE output forces one token refresh and retries once" do
    test_pid = self()
    counter = Codex.counter!()

    Application.put_env(:catalyst, :oauth_refresh_fun, fn _refresh_token ->
      send(test_pid, :refreshed)

      {:ok,
       %{
         "access" => "tok_new",
         "refresh" => "ref_2",
         "expires" => System.system_time(:millisecond) + 3_600_000,
         "account_id" => "acct"
       }}
    end)

    on_exit(fn -> Application.delete_env(:catalyst, :oauth_refresh_fun) end)

    # Fresh by expiry, but the server will reject it (revoked server-side).
    Codex.put_token!(%{access: "tok_old"})

    port = Codex.start_server!({Codex.StubCodex, %{counter: counter, test: test_pid}})

    model = Codex.model(port)
    context = Codex.context()
    sink = fn ev -> send(test_pid, {:ev, ev}) end

    # Pinned to :sse — this test is about the SSE 401-retry semantics; the
    # default :auto would prepend a websocket upgrade attempt per request.
    assert {:ok, assistant} =
             OpenAICodex.Provider.stream(model, context, [transport: :sse], sink)

    assert assistant.stop_reason == :stop
    assert Content.text_of(assistant.content) == "hi"

    # The 401 triggered exactly one forced refresh, then a retry with the new
    # token; the streamed text reached the sink only once.
    assert_received :refreshed
    assert_received {:codex_request, 1, "Bearer tok_old"}
    assert_received {:codex_request, 2, "Bearer tok_new"}
    refute_received {:codex_request, _, _}
    assert_received {:ev, %Catalyst.LLM.Event.TextDelta{delta: "hi"}}
    refute_received {:ev, %Catalyst.LLM.Event.TextDelta{}}
  end

  test "auto transport falls back to SSE when the websocket upgrade is rejected" do
    test_pid = self()

    Codex.put_token!()

    port = Codex.start_server!({Codex.UpgradeRejectingCodex, %{test: test_pid}})

    model = Codex.model(port)
    context = Codex.context()
    sink = fn ev -> send(test_pid, {:ev, ev}) end

    assert {:ok, assistant} =
             OpenAICodex.Provider.stream(model, context, [transport: :auto], sink)

    assert assistant.stop_reason == :stop
    assert Content.text_of(assistant.content) == "hi"

    # One websocket upgrade attempt (rejected), then the SSE fallback.
    assert_received {:codex_method, "GET"}
    assert_received {:codex_method, "POST"}
    refute_received {:codex_method, _}
    assert_received {:ev, %Catalyst.LLM.Event.TextDelta{delta: "hi"}}
    refute_received {:ev, %Catalyst.LLM.Event.TextDelta{}}
  end

  test "a 401 websocket upgrade forces one token refresh and retries over ws" do
    test_pid = self()

    Application.put_env(:catalyst, :oauth_refresh_fun, fn _refresh_token ->
      send(test_pid, :refreshed)

      {:ok,
       %{
         "access" => "tok_new",
         "refresh" => "ref_2",
         "expires" => System.system_time(:millisecond) + 3_600_000,
         "account_id" => "acct"
       }}
    end)

    on_exit(fn -> Application.delete_env(:catalyst, :oauth_refresh_fun) end)

    Codex.put_token!(%{access: "tok_old"})

    port = Codex.start_server!({Codex.PrivatePlug, {Codex.AuthWsRouter, test_pid}})

    model = Codex.model(port)
    context = Codex.context()

    assert {:ok, assistant} =
             OpenAICodex.Provider.stream(model, context, [transport: :websocket], fn _ -> :ok end)

    assert assistant.stop_reason == :stop
    assert Content.text_of(assistant.content) == "answer 1"

    assert_received :ws_upgrade_401
    assert_received :refreshed
    assert_received {:ws_request, _frame}
    refute_received :ws_upgrade_401
  end

  test "a ws dying after sink-visible events finalizes the partial turn instead of falling back" do
    test_pid = self()

    Codex.put_token!()

    port = Codex.start_server!({Codex.PrivatePlug, {Codex.PartialWsRouter, test_pid}})

    model = Codex.model(port)
    context = Codex.context()
    sink = fn ev -> send(test_pid, {:ev, ev}) end

    assert {:ok, assistant} =
             OpenAICodex.Provider.stream(model, context, [transport: :auto], sink)

    # The partial text is kept, the turn is marked errored, and no SSE
    # fallback fired (it would duplicate the delivered deltas).
    assert assistant.stop_reason == :error
    assert Content.text_of(assistant.content) =~ "oops partial"
    assert assistant.error_message =~ "before completion"

    assert_received {:ev, %Catalyst.LLM.Event.TextDelta{delta: "oops partial"}}
    refute_received :fallback_post
  end

  test "a 429 with retry-after is retried once and then succeeds" do
    test_pid = self()
    counter = Codex.counter!()

    Codex.put_token!()

    port = Codex.start_server!({Codex.RetryAfterCodex, %{counter: counter, test: test_pid}})

    model = Codex.model(port)
    context = Codex.context()

    assert {:ok, assistant} =
             OpenAICodex.Provider.stream(model, context, [transport: :sse], fn _ -> :ok end)

    assert assistant.stop_reason == :stop
    assert Content.text_of(assistant.content) == "hi"

    assert_received {:codex_request, 1}
    assert_received {:codex_request, 2}
    refute_received {:codex_request, _}
  end

  test "same-connection follow-up turns upload only new messages via previous_response_id" do
    Codex.put_token!()

    port = Codex.start_server!({Codex.PrivatePlug, {Codex.ContinuationRouter, self()}})

    model = Codex.model(port)
    sink = fn _ -> :ok end
    opts = [transport: :websocket, session_id: "cont-test"]

    # Turn 1: full upload, no continuation yet.
    ctx1 = %Context{system_prompt: "sys", messages: [Message.user("hi")], tools: []}
    assert {:ok, a1} = OpenAICodex.Provider.stream(model, ctx1, opts, sink)
    assert Content.text_of(a1.content) == "answer 1"
    assert a1.response_id == "resp_1"

    assert_receive {:ws_request, frame1}
    refute Map.has_key?(frame1, "previous_response_id")
    assert length(frame1["input"]) == 1

    # Turn 2 (same process = same run task = same cached connection): the
    # transcript grew by [assistant, new user message] — only the NEW user
    # message is uploaded, chained to resp_1.
    ctx2 = %Context{
      system_prompt: "sys",
      messages: ctx1.messages ++ [a1, Message.user("again")],
      tools: []
    }

    assert {:ok, a2} = OpenAICodex.Provider.stream(model, ctx2, opts, sink)
    assert Content.text_of(a2.content) == "answer 2"

    assert_receive {:ws_request, frame2}
    assert frame2["previous_response_id"] == "resp_1"
    assert [%{"role" => "user", "content" => [%{"text" => "again"} | _]}] = frame2["input"]

    # Turn 3 with a changed request option: the body probe mismatches, so the
    # delta is abandoned — full input, no previous_response_id.
    ctx3 = %Context{
      system_prompt: "sys",
      messages: ctx2.messages ++ [a2, Message.user("third")],
      tools: []
    }

    assert {:ok, _a3} =
             OpenAICodex.Provider.stream(
               model,
               ctx3,
               Keyword.put(opts, :reasoning_effort, "high"),
               sink
             )

    assert_receive {:ws_request, frame3}
    refute Map.has_key?(frame3, "previous_response_id")
    assert length(frame3["input"]) == 5
  end

  test "compacted history forces a full request and the next stable turn re-anchors" do
    Codex.put_token!()

    session_id = "compaction-delta-test"

    on_exit(fn -> Catalyst.LLM.OpenAICodex.ConnCache.drop(session_id) end)

    port = Codex.start_server!({Codex.PrivatePlug, {Codex.ContinuationRouter, self()}})

    model = Codex.model(port)
    opts = [transport: :websocket, session_id: session_id]
    sink = fn _event -> :ok end

    original = %Context{system_prompt: "sys", messages: [Message.user("old")], tools: []}
    assert {:ok, first} = OpenAICodex.Provider.stream(model, original, opts, sink)
    assert_receive {:ws_request, first_frame}
    refute Map.has_key?(first_frame, "previous_response_id")

    compacted = %Context{
      system_prompt: "sys",
      messages: [Message.user("summary"), Message.user("after compaction")],
      tools: []
    }

    assert {:ok, second} = OpenAICodex.Provider.stream(model, compacted, opts, sink)
    assert_receive {:ws_request, second_frame}
    refute Map.has_key?(second_frame, "previous_response_id")
    assert length(second_frame["input"]) == 2

    stable = %{
      compacted
      | messages: compacted.messages ++ [second, Message.user("stable follow-up")]
    }

    assert {:ok, _third} = OpenAICodex.Provider.stream(model, stable, opts, sink)
    assert_receive {:ws_request, third_frame}
    assert third_frame["previous_response_id"] == "resp_2"

    assert [%{"role" => "user", "content" => [%{"text" => "stable follow-up"} | _]}] =
             third_frame["input"]

    assert first.response_id == "resp_1"
  end

  test "the connection and continuation survive across runs (different processes)" do
    Codex.put_token!()

    port = Codex.start_server!({Codex.PrivatePlug, {Codex.ContinuationRouter, self()}})

    model = Codex.model(port)
    sink = fn _ -> :ok end
    opts = [transport: :websocket, session_id: "xrun-test"]

    # Run 1 (its own task process, like a real run).
    ctx1 = %Context{system_prompt: "sys", messages: [Message.user("hi")], tools: []}

    {:ok, a1} =
      Task.async(fn -> OpenAICodex.Provider.stream(model, ctx1, opts, sink) end)
      |> Task.await()

    assert_receive {:ws_request, frame1}
    refute Map.has_key?(frame1, "previous_response_id")

    # Run 2 in a DIFFERENT process: the ConnCache hands over the same socket
    # and continuation — the follow-up is a delta chained to run 1's response.
    ctx2 = %Context{
      system_prompt: "sys",
      messages: ctx1.messages ++ [a1, Message.user("second run")],
      tools: []
    }

    {:ok, a2} =
      Task.async(fn -> OpenAICodex.Provider.stream(model, ctx2, opts, sink) end)
      |> Task.await()

    assert Content.text_of(a2.content) == "answer 2"

    assert_receive {:ws_request, frame2}
    assert frame2["previous_response_id"] == "resp_1"
    assert [%{"role" => "user", "content" => [%{"text" => "second run"} | _]}] = frame2["input"]

    Catalyst.LLM.OpenAICodex.ConnCache.drop("xrun-test")
  end

  test "prewarm (generate: false) lets the FIRST turn ride a delta upload" do
    Codex.put_token!()

    port = Codex.start_server!({Codex.PrivatePlug, {Codex.ContinuationRouter, self()}})

    model = Codex.model(port)
    opts = [transport: :websocket, session_id: "warm-test"]

    # Prewarm with the empty transcript (what a fresh session sends).
    warm_ctx = %Context{system_prompt: "sys", messages: [], tools: []}
    assert :ok = OpenAICodex.Provider.prewarm(model, warm_ctx, opts)

    assert_receive {:ws_request, warm_frame}
    assert warm_frame["generate"] == false
    assert warm_frame["input"] == []

    # A second prewarm is a no-op — the connection is already cached.
    assert :ok = OpenAICodex.Provider.prewarm(model, warm_ctx, opts)
    refute_receive {:ws_request, _}, 100

    # Turn 1 rides the prewarmed continuation: delta with ONLY the user message.
    ctx1 = %Context{system_prompt: "sys", messages: [Message.user("hi")], tools: []}

    {:ok, a1} =
      Task.async(fn -> OpenAICodex.Provider.stream(model, ctx1, opts, fn _ -> :ok end) end)
      |> Task.await()

    assert Content.text_of(a1.content) == "answer 2"

    assert_receive {:ws_request, frame1}
    assert frame1["previous_response_id"] == "resp_1"
    refute Map.has_key?(frame1, "generate")
    assert [%{"role" => "user", "content" => [%{"text" => "hi"} | _]}] = frame1["input"]

    Catalyst.LLM.OpenAICodex.ConnCache.drop("warm-test")
  end

  test "a prewarm prompt mismatch retains the websocket but sends a full request" do
    Codex.put_token!()

    session_id = "warm-mismatch-test"

    on_exit(fn -> Catalyst.LLM.OpenAICodex.ConnCache.drop(session_id) end)

    port = Codex.start_server!({Codex.PrivatePlug, {Codex.ContinuationRouter, self()}})

    model = Codex.model(port)
    opts = [transport: :websocket, session_id: session_id]
    warm_context = %Context{system_prompt: "prewarm prompt", messages: [], tools: []}

    assert :ok = OpenAICodex.Provider.prewarm(model, warm_context, opts)
    assert_receive {:ws_request, %{"generate" => false}}

    run_context = %Context{
      system_prompt: "changed run prompt",
      messages: [Message.user("hi")],
      tools: []
    }

    assert {:ok, assistant} =
             OpenAICodex.Provider.stream(model, run_context, opts, fn _event -> :ok end)

    assert_receive {:ws_request, frame}
    refute Map.has_key?(frame, "previous_response_id")
    assert length(frame["input"]) == 1
    assert frame["instructions"] == "changed run prompt"
    assert Content.text_of(assistant.content) == "answer 2"
  end

  test "a failed prewarm response is never cached as a continuation anchor" do
    Codex.put_token!()

    port = Codex.start_server!({Codex.PrivatePlug, {Codex.ContinuationRouter, self()}})

    model = Codex.model(port)
    opts = [transport: :websocket, session_id: "failed-warm-test"]
    warm_ctx = %Context{system_prompt: "fail warmup", messages: [], tools: []}

    assert :ok = OpenAICodex.Provider.prewarm(model, warm_ctx, opts)
    assert_receive {:ws_request, %{"generate" => false}}

    ctx = %Context{system_prompt: "fail warmup", messages: [Message.user("hi")], tools: []}
    assert {:ok, assistant} = OpenAICodex.Provider.stream(model, ctx, opts, fn _ -> :ok end)
    assert Content.text_of(assistant.content) == "answer 2"

    assert_receive {:ws_request, frame}
    refute Map.has_key?(frame, "previous_response_id")
    assert length(frame["input"]) == 1

    Catalyst.LLM.OpenAICodex.ConnCache.drop("failed-warm-test")
  end

  test "auto transport still falls back to SSE when the socket dies after bookkeeping-only events" do
    test_pid = self()

    Codex.put_token!()

    port = Codex.start_server!({Codex.PrivatePlug, {Codex.BookkeepingRouter, test_pid}})

    model = Codex.model(port)
    context = Codex.context()
    sink = fn ev -> send(test_pid, {:ev, ev}) end

    assert {:ok, assistant} =
             OpenAICodex.Provider.stream(model, context, [transport: :auto], sink)

    # The websocket delivered only `response.created` (never forwarded to the
    # sink), so the fallback was safe — the SSE retry produced the full turn.
    assert assistant.stop_reason == :stop
    assert Content.text_of(assistant.content) == "hi"

    assert_received {:codex_method, "GET"}
    assert_received {:codex_method, "POST"}
    assert_received {:ev, %Catalyst.LLM.Event.TextDelta{delta: "hi"}}
    refute_received {:ev, %Catalyst.LLM.Event.TextDelta{}}
  end
end
