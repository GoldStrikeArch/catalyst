defmodule Catalyst.Test.Codex do
  @moduledoc """
  Shared Codex-provider test harness: token fixtures, supervised local Bandit
  servers, and the stub plugs/websockets used by the provider suite.

  Every stub module the provider tests exercise lives here so the test file
  reads as scenarios, not server boilerplate.
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias Catalyst.Auth.TokenStore
  alias Catalyst.LLM.{Context, OpenAICodex}
  alias Catalyst.Message

  @provider "openai-codex"

  @doc """
  Store Codex credentials (fresh by expiry unless overridden) and schedule
  their deletion on exit.
  """
  @spec put_token!(map()) :: :ok
  def put_token!(overrides \\ %{}) do
    creds =
      Map.merge(
        %{
          access: "tok_ok",
          refresh: "ref_1",
          expires: System.system_time(:millisecond) + 3_600_000,
          account_id: "acct"
        },
        overrides
      )

    :ok = TokenStore.put(@provider, creds)
    on_exit(fn -> TokenStore.delete(@provider) end)
    :ok
  end

  @doc "Start a supervised local Bandit server for `plug`; returns its port."
  @spec start_server!(module() | {module() | atom(), term()}) :: :inet.port_number()
  def start_server!(plug) do
    server =
      start_supervised!(
        {Bandit, plug: plug, scheme: :http, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    port
  end

  @doc "Supervised zero-initialized counter Agent for request-sequencing stubs."
  @spec counter!() :: pid()
  def counter!, do: start_supervised!({Agent, fn -> 0 end})

  @doc "Codex model pointed at the local stub server."
  @spec model(:inet.port_number()) :: Catalyst.Model.t()
  def model(port), do: OpenAICodex.model("gpt-test", base_url: "http://127.0.0.1:#{port}")

  @doc "Minimal single-user-message request context."
  @spec context(String.t()) :: Context.t()
  def context(prompt \\ "hi") do
    %Context{system_prompt: "x", messages: [Message.user(prompt)], tools: []}
  end

  defmodule UsageLimitCodex do
    @moduledoc "Always answers with a Codex-style usage-limit 429."
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{resets_at: resets_at}) do
      body =
        Jason.encode!(%{
          "error" => %{
            "code" => "usage_limit_reached",
            "message" => "Usage limit reached",
            "plan_type" => "Plus",
            "resets_at" => resets_at
          }
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(429, body)
    end
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

    @doc false
    def sse_body do
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

  defmodule UpgradeRejectingCodex do
    @moduledoc "Rejects websocket upgrades (GET 404) but serves SSE (POST 200)."
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{test: test}) do
      send(test, {:codex_method, conn.method})

      case conn.method do
        "GET" ->
          send_resp(conn, 404, "no websocket here")

        "POST" ->
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_resp(200, StubCodex.sse_body())
      end
    end
  end

  defmodule PrivatePlug do
    @moduledoc "Wraps a router, stashing the test pid in conn.private first."
    def init(opts), do: opts

    def call(conn, {router, test_pid}) do
      conn
      |> Plug.Conn.put_private(:test_pid, test_pid)
      |> router.call(router.init([]))
    end
  end

  defmodule BookkeepingOnlyWs do
    @moduledoc """
    Accepts the websocket upgrade, pushes ONE bookkeeping event (which
    `StreamParser` never forwards to the sink) and closes before the terminal
    event — the dying-early websocket the sink never heard from.
    """
    @behaviour WebSock

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_in({payload, opcode: :text}, state) do
      %{"type" => "response.create"} = Jason.decode!(payload)

      frame =
        {:text, Jason.encode!(%{"type" => "response.created", "response" => %{"id" => "r"}})}

      {:stop, :normal, 1000, [frame], state}
    end

    @impl true
    def handle_info(_msg, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  defmodule BookkeepingRouter do
    @moduledoc "Websocket upgrade to `BookkeepingOnlyWs`; SSE full turn on POST."
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/codex/responses" do
      send(conn.private.test_pid, {:codex_method, "GET"})
      WebSockAdapter.upgrade(conn, BookkeepingOnlyWs, %{}, timeout: 10_000)
    end

    post "/codex/responses" do
      send(conn.private.test_pid, {:codex_method, "POST"})

      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, StubCodex.sse_body())
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  defmodule ContinuationWs do
    @moduledoc "Echoes each response.create frame to the test, then serves a full turn."
    @behaviour WebSock

    @impl true
    def init(opts), do: {:ok, Map.put(opts, :turn, 0)}

    @impl true
    def handle_in({payload, opcode: :text}, state) do
      request = Jason.decode!(payload)
      send(state.test, {:ws_request, request})
      turn = state.turn + 1

      frames = frames(request, turn)

      {:push, frames, %{state | turn: turn}}
    end

    @impl true
    def handle_info(_msg, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok

    defp frames(
           %{"generate" => false, "instructions" => "fail warmup" <> _runtime_identity},
           turn
         ) do
      [
        text(%{"type" => "response.created", "response" => %{"id" => "resp_#{turn}"}}),
        text(%{
          "type" => "response.failed",
          "response" => %{
            "id" => "resp_#{turn}",
            "status" => "failed",
            "error" => %{"message" => "warmup rejected"}
          }
        })
      ]
    end

    defp frames(_request, turn) do
      [
        text(%{"type" => "response.created", "response" => %{"id" => "resp_#{turn}"}}),
        text(%{
          "type" => "response.output_item.added",
          "item" => %{"type" => "message", "id" => "m#{turn}"}
        }),
        text(%{"type" => "response.output_text.delta", "delta" => "answer #{turn}"}),
        text(%{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "id" => "m#{turn}",
            "content" => [%{"type" => "output_text", "text" => "answer #{turn}"}]
          }
        }),
        text(%{
          "type" => "response.completed",
          "response" => %{"id" => "resp_#{turn}", "status" => "completed"}
        })
      ]
    end

    defp text(map), do: {:text, Jason.encode!(map)}
  end

  defmodule ContinuationRouter do
    @moduledoc "Always upgrades to `ContinuationWs` with the stashed test pid."
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/codex/responses" do
      WebSockAdapter.upgrade(conn, ContinuationWs, %{test: conn.private.test_pid},
        timeout: 10_000
      )
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  defmodule AuthWsRouter do
    @moduledoc "Rejects the ws upgrade with 401 for the old token, accepts the new one."
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/codex/responses" do
      case get_req_header(conn, "authorization") do
        ["Bearer tok_new"] ->
          WebSockAdapter.upgrade(
            conn,
            ContinuationWs,
            %{test: conn.private.test_pid},
            timeout: 10_000
          )

        _old_or_missing ->
          send(conn.private.test_pid, :ws_upgrade_401)
          send_resp(conn, 401, ~s({"detail":"Unauthorized"}))
      end
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  defmodule PartialWs do
    @moduledoc "Streams sink-visible content, then closes BEFORE the terminal event."
    @behaviour WebSock

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_in({payload, opcode: :text}, state) do
      %{"type" => "response.create"} = Jason.decode!(payload)

      frames = [
        {:text,
         Jason.encode!(%{
           "type" => "response.output_item.added",
           "item" => %{"type" => "message", "id" => "m1"}
         })},
        {:text,
         Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "oops partial"})}
      ]

      {:stop, :normal, 1000, frames, state}
    end

    @impl true
    def handle_info(_msg, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  defmodule PartialWsRouter do
    @moduledoc "Upgrades to `PartialWs`; the SSE fallback POST reports itself."
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/codex/responses" do
      WebSockAdapter.upgrade(conn, PartialWs, %{}, timeout: 10_000)
    end

    post "/codex/responses" do
      send(conn.private.test_pid, :fallback_post)

      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, StubCodex.sse_body())
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  defmodule RetryAfterCodex do
    @moduledoc "429 + retry-after-ms on the first request, SSE 200 afterwards."
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{counter: counter, test: test}) do
      n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
      send(test, {:codex_request, n})

      case n do
        1 ->
          conn
          |> put_resp_header("retry-after-ms", "50")
          |> put_resp_content_type("application/json")
          |> send_resp(429, ~s({"error":{"code":"rate_limit_exceeded","message":"slow down"}}))

        _n ->
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_resp(200, StubCodex.sse_body())
      end
    end
  end
end
