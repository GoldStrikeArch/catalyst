defmodule Catalyst.LLM.OpenAICodex.WebSocket do
  @moduledoc """
  WebSocket transport for the Codex Responses API (Mint + Mint.WebSocket),
  following the Codex CLI's `responses_websocket` endpoint:

    * upgrade against the same `/codex/responses` path (`wss:`) with
      `OpenAI-Beta: responses_websockets=2026-02-06`;
    * one text frame `{"type":"response.create", ...request body...}` per turn;
    * the server streams Responses API events back as JSON text frames (the
      same payloads SSE carries in `data:`), ending with a terminal
      `response.completed` / `response.done` / `response.incomplete` /
      `response.failed` / `response.cancelled` / `error` event;
    * server pings are answered with pongs; a close before the terminal event
      is an error.

  The connection struct is plain data owned by one process at a time. During a
  request that is the agent-loop run task; between requests ownership may move
  to the bounded `ConnCache`. `request/4` is a fold: each decoded event map is
  fed to the caller's reducer (which feeds
  `Catalyst.LLM.OpenAICodex.StreamParser`), and the final accumulator comes
  back with the result, success or failure, along with how many decoded events
  reached the reducer (diagnostic — the caller judges retry/fallback safety by
  what reached its own sink, since bookkeeping events never do).
  """

  alias Catalyst.LLM.OpenAICodex.{BoundedBuffer, ResponseEvent}
  alias Catalyst.Tasks

  @upgrade_timeout 15_000
  @idle_timeout 600_000

  defstruct [:conn, :websocket, :ref, resp_headers: []]

  @type t :: %__MODULE__{
          conn: Mint.HTTP.t(),
          websocket: Mint.WebSocket.t(),
          ref: Mint.Types.request_ref(),
          # The 101 upgrade response headers (e.g. x-models-etag).
          resp_headers: [{String.t(), String.t()}]
        }

  @type reducer :: (map(), acc :: term() -> acc :: term())

  @doc "Guard matching TCP/SSL messages that may belong to a Mint connection."
  defguard is_socket_message(message)
           when is_tuple(message) and tuple_size(message) > 0 and
                  elem(message, 0) in [
                    :tcp,
                    :ssl,
                    :tcp_closed,
                    :ssl_closed,
                    :tcp_error,
                    :ssl_error
                  ]

  # ---- connect ----------------------------------------------------------------

  @doc """
  Connect and upgrade. `url` is the SSE endpoint URL (`http(s)://…/codex/responses`)
  or its `ws(s)://` form. Returns `{:ok, conn}`, `{:error, {:upgrade, status, body}}`
  for a rejected upgrade (e.g. 401 → caller refreshes the token), or
  `{:error, reason}` for transport failures.
  """
  @spec connect(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, t()} | {:error, term()}
  def connect(url, headers, opts \\ []) do
    uri = URI.parse(url)
    path = (uri.path || "/") <> query_suffix(uri.query)
    timeout = Keyword.get(opts, :timeout, @upgrade_timeout)

    with {:ok, http_scheme, ws_scheme} <- schemes(uri),
         {:ok, conn} <-
           Mint.HTTP.connect(http_scheme, uri.host, uri.port,
             protocols: [:http1],
             transport_opts: [timeout: timeout]
           ),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, headers) do
      deadline = Tasks.monotonic_ms() + timeout

      await_upgrade(
        %{conn: conn, ref: ref, status: nil, headers: [], body: BoundedBuffer.new()},
        deadline
      )
    else
      {:error, reason} ->
        {:error, reason}

      {:error, conn, reason} ->
        close_silently(conn)
        {:error, reason}
    end
  end

  defp schemes(%URI{scheme: "wss", host: host}) when is_binary(host) and host != "",
    do: {:ok, :https, :wss}

  defp schemes(%URI{scheme: "https", host: host}) when is_binary(host) and host != "",
    do: {:ok, :https, :wss}

  defp schemes(%URI{scheme: "ws", host: host}) when is_binary(host) and host != "",
    do: {:ok, :http, :ws}

  defp schemes(%URI{scheme: "http", host: host}) when is_binary(host) and host != "",
    do: {:ok, :http, :ws}

  defp schemes(%URI{scheme: scheme}), do: {:error, {:invalid_websocket_url_scheme, scheme}}

  defp query_suffix(nil), do: ""
  defp query_suffix(query), do: "?" <> query

  # Collect the upgrade response (101 → websocket; anything else → error with
  # the response body, so a 401 can drive the token-refresh retry).
  defp await_upgrade(%{conn: conn} = acc, deadline) do
    remaining = deadline - Tasks.monotonic_ms()

    case remaining > 0 do
      true -> receive_upgrade(acc, deadline, remaining)
      false -> upgrade_timeout(conn)
    end
  end

  defp receive_upgrade(%{conn: conn} = acc, deadline, remaining) do
    receive do
      msg when is_socket_message(msg) ->
        case Mint.WebSocket.stream(conn, msg) do
          {:ok, conn, entries} ->
            acc = %{acc | conn: conn}

            case Enum.reduce(entries, acc, &upgrade_entry/2) do
              %{done: true} = acc -> finish_upgrade(acc)
              acc -> await_upgrade(acc, deadline)
            end

          {:error, conn, reason, _entries} ->
            close_silently(conn)
            {:error, reason}

          :unknown ->
            await_upgrade(acc, deadline)
        end
    after
      remaining ->
        upgrade_timeout(conn)
    end
  end

  defp upgrade_timeout(conn) do
    close_silently(conn)
    {:error, :upgrade_timeout}
  end

  defp upgrade_entry({:status, ref, status}, %{ref: ref} = acc), do: Map.put(acc, :status, status)

  defp upgrade_entry({:headers, ref, headers}, %{ref: ref} = acc),
    do: %{acc | headers: acc.headers ++ headers}

  defp upgrade_entry({:data, ref, data}, %{ref: ref} = acc),
    do: %{acc | body: BoundedBuffer.append(acc.body, data)}

  defp upgrade_entry({:done, ref}, %{ref: ref} = acc), do: Map.put(acc, :done, true)
  defp upgrade_entry(_entry, acc), do: acc

  defp finish_upgrade(%{status: 101} = acc) do
    case new_websocket(acc.conn, acc.ref, acc.status, acc.headers) do
      {:ok, conn, websocket} ->
        {:ok,
         %__MODULE__{conn: conn, websocket: websocket, ref: acc.ref, resp_headers: acc.headers}}

      {:error, conn, reason} ->
        close_silently(conn)
        {:error, reason}
    end
  end

  defp finish_upgrade(acc) do
    close_silently(acc.conn)
    {:error, {:upgrade, acc.status, BoundedBuffer.to_binary(acc.body)}}
  end

  # ---- request ----------------------------------------------------------------

  @doc """
  Send one `response.create` request and fold the streamed event maps into
  `acc` with `reducer`. Returns `{:ok, conn, acc}` with the socket still open
  (reusable for the next turn), or `{:error, reason, acc, emitted}` with the
  socket closed — `emitted` says how many decoded events reached the reducer
  (diagnostic; whether an `:auto` caller may still fall back to SSE is judged
  by what reached its sink, not this count).
  """
  @spec request(t(), map() | binary(), term(), reducer(), keyword()) ::
          {:ok, t(), term()} | {:error, term(), term(), non_neg_integer()}
  def request(%__MODULE__{} = ws, body, acc, reducer, opts \\ []) do
    idle_timeout = Keyword.get(opts, :idle_timeout, @idle_timeout)
    frame = encode_request(body)

    # Pings (or a close) may have queued up while the connection idled between
    # turns; answering/diagnosing them BEFORE sending avoids writing into a
    # half-closed socket.
    with {:ok, ws} <- drain_idle(ws),
         {:ok, ws} <- send_frame(ws, {:text, frame}) do
      recv_loop(%{ws: ws, acc: acc, reducer: reducer, emitted: 0, done: false}, idle_timeout)
    else
      {:error, reason} ->
        close_silently(ws.conn)
        {:error, reason, acc, 0}
    end
  end

  @doc "Whether the underlying connection is still open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{conn: conn}), do: Mint.HTTP.open?(conn)

  @doc """
  Process one raw socket message for an IDLE connection (between requests):
  answers pings, ignores pongs/stray data, reports closes/errors. `:unknown`
  when the message does not belong to this connection — the caller (the
  connection cache) tries its other entries.
  """
  @spec handle_idle(t(), term()) :: {:ok, t()} | {:closed, term()} | :unknown
  def handle_idle(%__MODULE__{} = ws, msg) do
    case Mint.WebSocket.stream(ws.conn, msg) do
      :unknown ->
        :unknown

      {:ok, conn, entries} ->
        state = idle_state(%{ws | conn: conn})

        case handle_entries(state, entries) do
          {:cont, state} -> {:ok, state.ws}
          {:halt, {:error, reason, _acc, _emitted}} -> {:closed, reason}
        end

      {:error, conn, reason, _entries} ->
        close_silently(conn)
        {:closed, reason}
    end
  end

  @doc "Best-effort close (a close frame, then the socket)."
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = ws) do
    case send_frame(ws, :close) do
      {:ok, ws} -> close_silently(ws.conn)
      {:error, _reason} -> close_silently(ws.conn)
    end

    :ok
  end

  # ---- internals --------------------------------------------------------------

  defp recv_loop(%{done: true} = state, _idle_timeout), do: {:ok, state.ws, state.acc}

  defp recv_loop(state, idle_timeout) do
    receive do
      msg when is_socket_message(msg) ->
        case handle_socket_message(state, msg) do
          {:cont, state} -> recv_loop(state, idle_timeout)
          {:halt, result} -> result
        end
    after
      idle_timeout ->
        fail(state, :idle_timeout)
    end
  end

  defp handle_socket_message(state, msg) do
    case Mint.WebSocket.stream(state.ws.conn, msg) do
      {:ok, conn, entries} ->
        handle_entries(put_conn(state, conn), entries)

      {:error, conn, reason, _entries} ->
        {:halt, fail(put_conn(state, conn), reason)}

      :unknown ->
        {:cont, state}
    end
  end

  defp handle_entries(state, entries) do
    entries
    |> Enum.reduce_while(state, fn
      {:data, ref, data}, state when ref == state.ws.ref ->
        case decode_frames(state, data) do
          {:cont, state} -> {:cont, state}
          {:halt, result} -> {:halt, {:halt, result}}
        end

      {:done, _ref}, state ->
        # The server finished the HTTP/1 stream (connection closing).
        case state.done do
          true -> {:cont, state}
          false -> {:halt, {:halt, fail(state, :closed)}}
        end

      _entry, state ->
        {:cont, state}
    end)
    |> case do
      {:halt, result} -> {:halt, result}
      state -> {:cont, state}
    end
  end

  defp decode_frames(state, data) do
    case Mint.WebSocket.decode(state.ws.websocket, data) do
      {:ok, websocket, frames} ->
        state = put_websocket(state, websocket)

        Enum.reduce_while(frames, {:cont, state}, fn frame, {:cont, state} ->
          case handle_frame(state, frame) do
            {:cont, _state} = cont -> {:cont, cont}
            {:halt, _result} = halt -> {:halt, halt}
          end
        end)

      {:error, websocket, reason} ->
        {:halt, fail(put_websocket(state, websocket), reason)}
    end
  end

  defp handle_frame(state, {:text, payload}) do
    case Jason.decode(payload) do
      {:ok, %{"type" => _type} = event} ->
        event = ResponseEvent.normalize(event)
        state = %{state | acc: state.reducer.(event, state.acc), emitted: state.emitted + 1}

        case ResponseEvent.terminal?(event) do
          true -> {:cont, %{state | done: true}}
          false -> {:cont, state}
        end

      {:ok, _non_event} ->
        {:cont, state}

      {:error, reason} ->
        {:halt, fail(state, {:bad_frame_json, reason})}
    end
  end

  defp handle_frame(state, {:ping, payload}) do
    case send_frame(state.ws, {:pong, payload}) do
      {:ok, ws} -> {:cont, %{state | ws: ws}}
      {:error, reason} -> {:halt, fail(state, reason)}
    end
  end

  defp handle_frame(state, {:pong, _payload}), do: {:cont, state}

  defp handle_frame(%{done: true} = state, {:close, _code, _reason}), do: {:cont, state}

  defp handle_frame(state, {:close, code, reason}),
    do: {:halt, fail(state, {:ws_closed, code, reason})}

  defp handle_frame(state, {:error, reason}),
    do: {:halt, fail(state, {:frame_decode_error, reason})}

  defp handle_frame(state, _other), do: {:cont, state}

  defp fail(state, reason) do
    close_silently(state.ws.conn)
    {:error, reason, state.acc, state.emitted}
  end

  defp send_frame(%__MODULE__{} = ws, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(ws.websocket, frame),
         ws = %{ws | websocket: websocket},
         {:ok, conn} <- stream_request_body(ws.conn, ws.ref, data) do
      {:ok, %{ws | conn: conn}}
    else
      {:error, _state, reason} -> {:error, reason}
    end
  end

  defp stream_request_body(conn, ref, data) do
    Mint.WebSocket.stream_request_body(conn, ref, data)
  rescue
    exception in FunctionClauseError ->
      {:error, conn, {:invalid_connection_state, Exception.message(exception)}}
  end

  # Process queued socket messages from the idle period between turns:
  # answer pings, ignore pongs/data, and surface a server close/socket error
  # as `{:error, ...}` so the caller reconnects instead of writing to a dead
  # connection.
  defp drain_idle(%__MODULE__{} = ws) do
    receive do
      msg when is_socket_message(msg) ->
        state = idle_state(ws)

        case handle_socket_message(state, msg) do
          {:cont, state} -> drain_idle(state.ws)
          {:halt, {:error, reason, _acc, _emitted}} -> {:error, reason}
        end
    after
      0 -> {:ok, ws}
    end
  end

  defp put_conn(state, conn), do: %{state | ws: %{state.ws | conn: conn}}
  defp put_websocket(state, websocket), do: %{state | ws: %{state.ws | websocket: websocket}}

  defp idle_state(ws) do
    %{ws: ws, acc: nil, reducer: fn _event, acc -> acc end, emitted: 0, done: false}
  end

  defp encode_request(frame) when is_binary(frame), do: frame
  defp encode_request(body), do: body |> Map.put("type", "response.create") |> Jason.encode!()

  # `mint_web_socket` 1.0.5's inferred success type for new/4 collapses to its
  # error branch under Dialyzer even though its public contract and runtime both
  # return {:ok, conn, websocket}. Calling through apply/3 keeps this upstream
  # success-typing defect from making connect/3 look like it can never succeed.
  defp new_websocket(conn, ref, status, headers) do
    apply(Mint.WebSocket, :new, [conn, ref, status, headers])
  end

  defp close_silently(conn) do
    Mint.HTTP.close(conn)
    :ok
  catch
    _kind, _reason -> :ok
  end
end
