defmodule Catalyst.LLM.OpenAICodex.WebSocketTest do
  # async: false — binds real TCP ports.
  use ExUnit.Case, async: false

  alias Catalyst.LLM.OpenAICodex.WebSocket

  # A scripted stand-in for the Codex Responses websocket endpoint. On each
  # `response.create` frame it pings the client first and only finishes the
  # response once the pong arrives — so a green test proves ping handling, the
  # event stream, AND connection reuse across requests.
  defmodule Handler do
    @behaviour WebSock

    @impl true
    def init(opts), do: {:ok, Map.put(opts, :turn, 0)}

    @impl true
    def handle_in({payload, opcode: :text}, state) do
      %{"type" => "response.create"} = Jason.decode!(payload)
      turn = state.turn + 1
      state = %{state | turn: turn}

      case state.mode do
        "happy" ->
          frames =
            [
              {:ping, "are-you-there"},
              text(%{"type" => "response.created", "response" => %{"id" => "resp_#{turn}"}}),
              text(%{"type" => "response.output_text.delta", "delta" => "hel"}),
              text(%{"type" => "response.output_text.delta", "delta" => "lo"})
            ]

          {:push, frames, state}

        "truncate" ->
          # Push one event, then close BEFORE the terminal event.
          frames = [text(%{"type" => "response.output_text.delta", "delta" => "oops"})]
          {:stop, :normal, 1000, frames, state}

        "invalid" ->
          {:push, [{:text, <<255>>}], state}
      end
    end

    @impl true
    def handle_control({_payload, opcode: :pong}, %{mode: "happy"} = state) do
      # Terminal frame only after the client's pong: turn 1 ends with the
      # older "response.done" alias (the client must normalize it), turn 2
      # with the modern "response.completed".
      type = if state.turn == 1, do: "response.done", else: "response.completed"

      frame =
        text(%{
          "type" => type,
          "response" => %{"id" => "resp_#{state.turn}", "status" => "completed"}
        })

      {:push, [frame], state}
    end

    def handle_control(_frame, state), do: {:ok, state}

    @impl true
    def handle_info(_msg, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok

    defp text(map), do: {:text, Jason.encode!(map)}
  end

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/codex/responses" do
      conn = Plug.Conn.fetch_query_params(conn)
      mode = conn.query_params["mode"] || "happy"
      WebSockAdapter.upgrade(conn, Handler, %{mode: mode}, timeout: 10_000)
    end

    get "/denied" do
      send_resp(conn, 401, "no token for you")
    end

    get "/denied-large" do
      send_resp(conn, 403, String.duplicate("x", 100_000))
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  setup do
    # Bandit.start_link returns the ThousandIsland supervisor, so listener_info
    # works on it directly (port 0 → the OS picks a free port).
    pid = start_supervised!({Bandit, plug: Router, scheme: :http, ip: :loopback, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, port: port}
  end

  defp collect(event, acc), do: [event | acc]

  test "streams events over one connection across two requests (ping→pong, done-normalization)",
       %{port: port} do
    url = "ws://127.0.0.1:#{port}/codex/responses?mode=happy"

    assert {:ok, conn} = WebSocket.connect(url, [{"origin-test", "1"}])

    # Turn 1: server ends with "response.done" — normalized to completed.
    assert {:ok, conn, events} = WebSocket.request(conn, %{"model" => "m"}, [], &collect/2)
    types = events |> Enum.reverse() |> Enum.map(& &1["type"])

    assert types == [
             "response.created",
             "response.output_text.delta",
             "response.output_text.delta",
             "response.completed"
           ]

    # Turn 2 reuses the SAME connection (drain_idle path) and gets resp_2.
    assert WebSocket.open?(conn)
    assert {:ok, conn, events2} = WebSocket.request(conn, %{"model" => "m"}, [], &collect/2)
    assert [%{"response" => %{"id" => "resp_2"}} | _rest] = events2

    WebSocket.close(conn)
  end

  test "accepts a response.create frame that the caller already encoded", %{port: port} do
    url = "ws://127.0.0.1:#{port}/codex/responses?mode=happy"
    frame = Jason.encode!(%{"type" => "response.create", "model" => "m"})

    assert {:ok, conn} = WebSocket.connect(url, [])
    assert {:ok, conn, events} = WebSocket.request(conn, frame, [], &collect/2)
    assert Enum.any?(events, &(&1["type"] == "response.completed"))
    WebSocket.close(conn)
  end

  test "an initial send failure closes the checked-out socket", %{port: port} do
    url = "ws://127.0.0.1:#{port}/codex/responses?mode=happy"

    assert {:ok, conn} = WebSocket.connect(url, [])
    socket = conn.conn.socket
    invalid = %{conn | ref: make_ref()}

    assert {:error, _reason, [], 0} =
             WebSocket.request(invalid, %{"model" => "m"}, [], &collect/2)

    assert Port.info(socket) == nil
  end

  test "a close before the terminal event is an error that reports emitted events",
       %{port: port} do
    url = "ws://127.0.0.1:#{port}/codex/responses?mode=truncate"

    assert {:ok, conn} = WebSocket.connect(url, [])

    assert {:error, _reason, events, emitted} =
             WebSocket.request(conn, %{"model" => "m"}, [], &collect/2)

    assert emitted == 1
    assert [%{"type" => "response.output_text.delta"}] = events
  end

  test "a rejected upgrade surfaces the HTTP status and body", %{port: port} do
    url = "ws://127.0.0.1:#{port}/denied"

    assert {:error, {:upgrade, 401, body}} = WebSocket.connect(url, [])
    assert body =~ "no token"
  end

  test "a rejected upgrade caps its response body", %{port: port} do
    url = "ws://127.0.0.1:#{port}/denied-large"

    assert {:error, {:upgrade, 403, body}} = WebSocket.connect(url, [])
    assert byte_size(body) == 65_536
  end

  test "connecting to a closed port is a tagged error", %{port: port} do
    # The Bandit server from setup is NOT on port+1; grab a port nothing
    # listens on by binding and closing it.
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, free_port} = :inet.port(socket)
    :gen_tcp.close(socket)

    assert {:error, _reason} = WebSocket.connect("ws://127.0.0.1:#{free_port}/x", [])
    assert port > 0
  end

  test "rejects unknown and missing URL schemes before connecting" do
    assert {:error, {:invalid_websocket_url_scheme, "ftp"}} =
             WebSocket.connect("ftp://example.com/codex/responses", [])

    assert {:error, {:invalid_websocket_url_scheme, nil}} =
             WebSocket.connect("example.com/codex/responses", [])
  end

  test "a decoded frame error closes the request instead of being ignored", %{port: port} do
    url = "ws://127.0.0.1:#{port}/codex/responses?mode=invalid"
    assert {:ok, conn} = WebSocket.connect(url, [])

    assert {:error, reason, [], 0} =
             WebSocket.request(conn, %{"model" => "m"}, [], &collect/2, idle_timeout: 1_000)

    refute reason == :idle_timeout
  end
end
