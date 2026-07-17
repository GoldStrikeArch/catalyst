defmodule Catalyst.LLM.OpenAICodex.ProviderTest do
  use ExUnit.Case, async: false

  alias Catalyst.Auth.TokenStore
  alias Catalyst.LLM.Context
  alias Catalyst.LLM.OpenAICodex
  alias Catalyst.{Content, Message}

  test "returns an error assistant (never raises) when not authenticated" do
    model = OpenAICodex.model("gpt-5.4")
    context = %Context{system_prompt: "x", messages: [Message.user("hi")], tools: []}

    assert {:ok, assistant} = OpenAICodex.Provider.stream(model, context, [], fn _ -> :ok end)
    assert assistant.stop_reason == :error
    assert assistant.error_message =~ "not authenticated"
    assert assistant.api == "openai-codex-responses"
  end

  test "the api is registered to the Codex provider" do
    assert {:ok, OpenAICodex.Provider} = Catalyst.LLM.Registry.fetch("openai-codex-responses")
  end

  defmodule StubCodex do
    @moduledoc "Local Codex stub: 401 on the first request, an SSE 200 afterwards."
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{counter: counter, test: test}) do
      n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
      [auth] = get_req_header(conn, "authorization")
      send(test, {:codex_request, n, auth})
      respond(conn, n)
    end

    defp respond(conn, 1) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, ~s({"detail":"Unauthorized"}))
    end

    defp respond(conn, _n) do
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, sse_body())
    end

    defp sse_body do
      [
        %{"type" => "response.output_item.added", "item" => %{"type" => "message", "id" => "m1"}},
        %{"type" => "response.output_text.delta", "delta" => "hi"},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "id" => "m1",
            "content" => [%{"type" => "output_text", "text" => "hi"}]
          }
        },
        %{"type" => "response.completed", "response" => %{"id" => "r1", "status" => "completed"}}
      ]
      |> Enum.map_join("", fn ev -> "data: " <> Jason.encode!(ev) <> "\n\n" end)
    end
  end

  test "a 401 before any SSE output forces one token refresh and retries once" do
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

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

    on_exit(fn ->
      Application.delete_env(:catalyst, :oauth_refresh_fun)
      TokenStore.delete("openai-codex")
    end)

    # Fresh by expiry, but the server will reject it (revoked server-side).
    :ok =
      TokenStore.put("openai-codex", %{
        access: "tok_old",
        refresh: "ref_1",
        expires: System.system_time(:millisecond) + 3_600_000,
        account_id: "acct"
      })

    {:ok, server} =
      Bandit.start_link(
        plug: {StubCodex, %{counter: counter, test: test_pid}},
        scheme: :http,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    model = OpenAICodex.model("gpt-test", base_url: "http://127.0.0.1:#{port}")
    context = %Context{system_prompt: "x", messages: [Message.user("hi")], tools: []}
    sink = fn ev -> send(test_pid, {:ev, ev}) end

    assert {:ok, assistant} = OpenAICodex.Provider.stream(model, context, [], sink)

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
end
