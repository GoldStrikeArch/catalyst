defmodule Catalyst.LLM.GrokSubscription.ProviderTest do
  use ExUnit.Case, async: false

  alias Catalyst.{Content, Message}
  alias Catalyst.Auth.{TokenStore, XAIOAuth}
  alias Catalyst.LLM.{Context, Event}
  alias Catalyst.LLM.GrokSubscription
  alias Catalyst.LLM.GrokSubscription.{Provider, Request}

  defmodule GrokPlug do
    @moduledoc false

    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(%Plug.Conn{request_path: "/v1/chat/completions"} = conn, test_pid) do
      {:ok, body, conn} = read_body(conn)
      send(test_pid, {:grok_request, Jason.decode!(body), conn.req_headers})

      events = [
        %{
          "id" => "chatcmpl-1",
          "model" => "grok-4.6",
          "choices" => [%{"delta" => %{"reasoning_content" => "checking"}}]
        },
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "function" => %{"name" => "grep", "arguments" => "{\"pattern\":"}
                  }
                ]
              }
            }
          ]
        },
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{"index" => 0, "function" => %{"arguments" => "\"TODO\"}"}}
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        },
        %{
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 12,
            "completion_tokens" => 4,
            "total_tokens" => 16,
            "prompt_tokens_details" => %{"cached_tokens" => 3}
          }
        }
      ]

      body = Enum.map_join(events, "", &"data: #{Jason.encode!(&1)}\n\n") <> "data: [DONE]\n\n"

      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, body)
    end
  end

  setup do
    provider = XAIOAuth.provider_id()

    :ok =
      TokenStore.put(provider, %{
        access: "subscription-token",
        refresh: "refresh-token",
        expires: System.system_time(:millisecond) + 3_600_000,
        account_id: "xai-user"
      })

    on_exit(fn -> TokenStore.delete(provider) end)
    :ok
  end

  test "streams Grok reasoning and validated tool calls over the subscription proxy contract" do
    server =
      start_supervised!({Bandit, plug: {GrokPlug, self()}, scheme: :http, ip: :loopback, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    model = GrokSubscription.model("grok-4.6", base_url: "http://127.0.0.1:#{port}/v1")

    context = %Context{
      system_prompt: "You are concise.",
      messages: [Message.user("Find TODOs")],
      tools: [
        %{name: "grep", description: "Search files", parameters: %{"type" => "object"}}
      ]
    }

    sink = fn event -> send(self(), {:event, event}) end

    assert {:ok, assistant} =
             Provider.stream(
               model,
               context,
               [reasoning_effort: "xhigh", session_id: "session-1"],
               sink
             )

    assert_receive {:grok_request, request, headers}
    assert request["model"] == "grok-4.6"
    assert request["reasoning_effort"] == "xhigh"
    assert request["stream_options"] == %{"include_usage" => true}
    assert get_in(request, ["tools", Access.at(0), "function", "name"]) == "grep"
    assert {"authorization", "Bearer subscription-token"} in headers
    assert {"x-xai-token-auth", "xai-grok-cli"} in headers
    assert {"x-grok-model-override", "grok-4.6"} in headers
    assert {"x-grok-session-id", "session-1"} in headers

    assert assistant.stop_reason == :tool_use
    assert assistant.response_id == "chatcmpl-1"
    assert assistant.usage.input == 9
    assert assistant.usage.cache_read == 3

    assert [
             %Content.Thinking{thinking: "checking"},
             %Content.ToolCall{
               id: "call_1",
               name: "grep",
               arguments: %{"pattern" => "TODO"}
             }
           ] = assistant.content

    assert_received {:event, %Event.ThinkingDelta{delta: "checking"}}
    assert_received {:event, %Event.ToolCallStart{id: "call_1", name: "grep"}}
    assert_received {:event, %Event.ToolCallDelta{id: "call_1", delta: "{\"pattern\":"}}
    assert_received {:event, %Event.ToolCallEnd{arguments: %{"pattern" => "TODO"}}}
  end

  test "malformed tool arguments are never returned as executable tool calls" do
    parser = Catalyst.LLM.GrokSubscription.StreamParser.new()

    event = %{
      "choices" => [
        %{
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "bad-call",
                "function" => %{"name" => "bash", "arguments" => "{not-json"}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ]
    }

    parser =
      Catalyst.LLM.GrokSubscription.StreamParser.handle(parser, event, fn _event -> :ok end)

    assistant =
      Catalyst.LLM.GrokSubscription.StreamParser.finalize(
        parser,
        GrokSubscription.model()
      )

    assert assistant.stop_reason == :error
    assert assistant.error_message =~ "invalid arguments for tool bash"
    refute Enum.any?(assistant.content, &match?(%Content.ToolCall{}, &1))
  end

  test "preserves the base64 payload of image content" do
    context = %Context{
      messages: [
        Message.user([
          %Content.Text{text: "inspect this"},
          %Content.Image{data: "QUJD", mime_type: "image/png"}
        ])
      ]
    }

    request = Request.build(GrokSubscription.model(), context, [])

    assert get_in(request, [
             "messages",
             Access.at(0),
             "content",
             Access.at(1),
             "image_url",
             "url"
           ]) == "data:image/png;base64,QUJD"
  end

  test "returns an error assistant when no model is configured" do
    assert {:ok, assistant} = Provider.stream(nil, %Context{}, [], fn _event -> :ok end)

    assert assistant.stop_reason == :error
    assert assistant.error_message == "no Grok model is configured for this session"
    assert assistant.api == "grok-subscription-chat-completions"
    assert assistant.provider == "grok-subscription"
    assert assistant.model == nil
  end

  test "model/0 honors the configured Grok default" do
    previous = Application.get_env(:catalyst, :grok_model, :not_set)
    Application.put_env(:catalyst, :grok_model, "configured-grok")

    on_exit(fn ->
      case previous do
        :not_set -> Application.delete_env(:catalyst, :grok_model)
        value -> Application.put_env(:catalyst, :grok_model, value)
      end
    end)

    assert GrokSubscription.default_model_id() == "configured-grok"
    assert GrokSubscription.model().id == "configured-grok"
  end
end
