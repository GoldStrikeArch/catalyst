defmodule Catalyst.LLM.OpenAICodex.Provider do
  @moduledoc """
  OpenAI Codex (ChatGPT subscription) provider over the Responses API at
  `https://chatgpt.com/backend-api/codex/responses`.

  Two transports (`opts[:transport]`, else `config :catalyst, :codex_transport`,
  default `:auto`):

    * `:websocket` — the Codex CLI's preferred transport (`prefer_websockets`
      in its model catalog): one `response.create` text frame per turn, events
      back as JSON frames. The connection is cached in the run task's process
      dictionary, so consecutive turns of one run reuse it — and it can never
      outlive the run, because the socket dies with its owning process.
    * `:sse` — POST + `text/event-stream` (the original transport).
    * `:auto` — websocket, falling back to SSE when the websocket fails before
      any event reached the sink (a fallback after delivery would duplicate
      events; a mid-stream failure finalizes the partial turn instead, exactly
      like an SSE transport close).

  Per the `Catalyst.LLM.Provider` contract it never raises: auth/HTTP/stream
  failures come back as a final assistant with `stop_reason: :error`.
  """

  @behaviour Catalyst.LLM.Provider

  require Logger

  alias Catalyst.{Content, Debug, Message}
  alias Catalyst.Auth.TokenStore
  alias Catalyst.LLM.SSE
  alias Catalyst.LLM.OpenAICodex.{Headers, Request, StreamParser, WebSocket}

  @default_base "https://chatgpt.com/backend-api"
  # TokenStore key for the ChatGPT OAuth credentials (single source).
  @auth_provider Catalyst.Auth.OpenAIOAuth.provider_id()
  @receive_timeout 600_000

  @impl true
  def stream(model, context, opts, sink) do
    case TokenStore.get_access_token(@auth_provider) do
      {:ok, %{access: token, account_id: account_id}} ->
        do_stream(model, context, opts, sink, token, account_id)

      {:error, reason} ->
        {:ok,
         error_assistant(
           model,
           "not authenticated (#{inspect(reason)}). Sign in to ChatGPT from the header " <>
             "(or run Catalyst.Auth.login_openai_codex/0)."
         )}
    end
  end

  # One forced-refresh retry on 401: the token can be revoked/expired server-side
  # despite the local 60s freshness margin. A 401 means no SSE event has reached
  # the sink (non-200 bodies are collected, not parsed), so the retry is
  # invisible to the caller. 429/5xx retries are deliberately NOT done here.
  defp do_stream(model, context, opts, sink, token, account_id) do
    case attempt(model, context, opts, sink, token, account_id) do
      {:unauthorized, body} -> retry_unauthorized(model, context, opts, sink, body)
      {:ok, assistant} -> {:ok, assistant}
    end
  end

  defp retry_unauthorized(model, context, opts, sink, body) do
    :ok = TokenStore.invalidate(@auth_provider)

    case TokenStore.get_access_token(@auth_provider) do
      {:ok, %{access: token, account_id: account_id}} ->
        case attempt(model, context, opts, sink, token, account_id) do
          # A second 401 is terminal — report it like any other HTTP error.
          {:unauthorized, body2} -> {:ok, error_assistant(model, http_error(401, body2))}
          {:ok, assistant} -> {:ok, assistant}
        end

      {:error, reason} ->
        {:ok,
         error_assistant(
           model,
           "#{http_error(401, body)} (token refresh also failed: #{inspect(reason)})"
         )}
    end
  end

  defp http_error(status, body), do: "HTTP #{status}: #{String.slice(body, 0, 600)}"

  defp attempt(model, context, opts, sink, token, account_id) do
    session_id = opts[:session_id] || random_id()
    body = Request.build(model, context, Keyword.put(opts, :session_id, session_id))

    case resolve_transport(opts) do
      :sse -> attempt_sse(model, body, sink, token, account_id, session_id)
      :websocket -> attempt_ws(model, body, sink, token, account_id, session_id, false)
      :auto -> attempt_ws(model, body, sink, token, account_id, session_id, true)
    end
  end

  defp resolve_transport(opts) do
    normalize_transport(
      opts[:transport] || Application.get_env(:catalyst, :codex_transport, :auto)
    )
  end

  defp normalize_transport(t) when t in [:auto, :websocket, :sse], do: t
  defp normalize_transport("websocket"), do: :websocket
  defp normalize_transport("sse"), do: :sse
  defp normalize_transport(_other), do: :auto

  # ---- websocket transport ----------------------------------------------------

  # The run task's process dictionary caches the connection: turn N+1 of the
  # same run reuses turn N's socket, and the socket cannot leak — it closes
  # with the owning process when the run ends or is aborted.
  @ws_conn_key {__MODULE__, :ws_conn}

  defp attempt_ws(model, body, sink, token, account_id, session_id, fallback?) do
    url = resolve_url(model)
    headers = Headers.websocket(token, account_id, session_id)

    case checkout_ws(url, headers, session_id) do
      {:ok, conn, reused?} ->
        run_ws_request(conn, reused?, model, body, sink, token, account_id, session_id, fallback?)

      # A rejected upgrade carries the HTTP response — a 401 drives the same
      # forced-refresh retry as the SSE path.
      {:error, {:upgrade, 401, resp_body}} ->
        Debug.log(session_id, "codex.response", "ws upgrade 401")
        {:unauthorized, resp_body}

      {:error, reason} ->
        ws_failure(model, body, sink, token, account_id, session_id, fallback?, reason)
    end
  end

  defp checkout_ws(url, headers, session_id) do
    case Process.get(@ws_conn_key) do
      {^url, conn} ->
        case WebSocket.open?(conn) do
          true ->
            {:ok, conn, true}

          false ->
            Process.delete(@ws_conn_key)
            connect_ws(url, headers, session_id)
        end

      _none_or_other_url ->
        connect_ws(url, headers, session_id)
    end
  end

  defp connect_ws(url, headers, session_id) do
    Debug.log(session_id, "codex.request", "ws connect #{url}")

    case WebSocket.connect(url, headers) do
      {:ok, conn} -> {:ok, conn, false}
      {:error, _reason} = err -> err
    end
  end

  defp run_ws_request(conn, reused?, model, body, sink, token, account_id, session_id, fallback?) do
    Debug.log(
      session_id,
      "codex.request",
      "ws response.create model=#{model.id} reused=#{reused?} " <>
        "body=#{Debug.truncate(Jason.encode!(body), 3_000)}"
    )

    reducer = fn event, parser -> StreamParser.handle(parser, event, sink) end

    case WebSocket.request(conn, body, StreamParser.new(), reducer) do
      {:ok, conn, parser} ->
        Process.put(@ws_conn_key, {resolve_url(model), conn})
        Debug.log(session_id, "codex.response", "ws ok")
        {:ok, StreamParser.finalize(parser, model)}

      # Events already reached the sink — finalize the partial turn (same rule
      # as an SSE transport close after 200); a fallback would duplicate them.
      {:error, reason, parser, emitted} when emitted > 0 ->
        Process.delete(@ws_conn_key)
        Debug.log(session_id, "codex.error", "ws closed mid-response: #{inspect(reason)}")
        {:ok, StreamParser.finalize(parser, model)}

      {:error, reason, _parser, 0} when reused? ->
        # A cached connection can go stale while tools ran — retry once on a
        # fresh socket before considering fallback.
        Process.delete(@ws_conn_key)

        Debug.log(
          session_id,
          "codex.error",
          "ws reused conn failed (#{inspect(reason)}) — reconnecting"
        )

        attempt_ws(model, body, sink, token, account_id, session_id, fallback?)

      {:error, reason, _parser, 0} ->
        Process.delete(@ws_conn_key)
        ws_failure(model, body, sink, token, account_id, session_id, fallback?, reason)
    end
  end

  defp ws_failure(model, body, sink, token, account_id, session_id, true = _fallback?, reason) do
    Debug.log(
      session_id,
      "codex.error",
      "websocket failed before any event (#{inspect(reason)}) — falling back to SSE"
    )

    attempt_sse(model, body, sink, token, account_id, session_id)
  end

  defp ws_failure(model, _body, _sink, _token, _account_id, session_id, false, reason) do
    Debug.log(session_id, "codex.error", "websocket failed: #{inspect(reason)}")
    {:ok, error_assistant(model, "websocket error: #{inspect(reason)}")}
  end

  # ---- SSE transport ------------------------------------------------------------

  defp attempt_sse(model, body_map, sink, token, account_id, session_id) do
    url = resolve_url(model)
    headers = Headers.build(token, account_id, session_id)
    body = Jason.encode!(body_map)

    request = Finch.build(:post, url, headers, body)

    acc = %{status: nil, buffer: "", parser: StreamParser.new(), sink: sink, error_body: ""}

    Debug.log(
      session_id,
      "codex.request",
      "POST #{url} model=#{model.id} bytes=#{byte_size(body)} body=#{Debug.truncate(body, 3_000)}"
    )

    # `Finch.stream/5` returns `{:ok, acc}` on completion, or `{:error, exception,
    # partial_acc}` (a 3-tuple) on a transport failure — handle BOTH or a dropped
    # connection (e.g. `%Finch.TransportError{reason: :closed}`) crashes the run.
    case Finch.stream(request, Catalyst.Finch, acc, &handle_chunk/2,
           receive_timeout: @receive_timeout
         ) do
      {:ok, %{status: 200, parser: parser}} ->
        Debug.log(session_id, "codex.response", "200 ok")
        {:ok, StreamParser.finalize(parser, model)}

      # Bubble a 401 up so do_stream can force-refresh and retry once.
      {:ok, %{status: 401, error_body: body}} ->
        Debug.log(session_id, "codex.response", "HTTP 401 body=#{Debug.truncate(body, 1_500)}")
        {:unauthorized, body}

      {:ok, %{status: status, error_body: body}} ->
        Debug.log(
          session_id,
          "codex.response",
          "HTTP #{status} body=#{Debug.truncate(body, 1_500)}"
        )

        {:ok, error_assistant(model, http_error(status, body))}

      # Connection dropped after a 200 with partial data — keep what we parsed.
      {:error, reason, %{status: 200, parser: parser}} ->
        Debug.log(session_id, "codex.error", "stream closed mid-response: #{inspect(reason)}")
        {:ok, StreamParser.finalize(parser, model)}

      {:error, reason, partial} ->
        Debug.log(
          session_id,
          "codex.error",
          "transport error: #{inspect(reason)} (status=#{inspect(partial[:status])})"
        )

        {:ok, error_assistant(model, stream_error_message(reason))}
    end
  end

  defp stream_error_message(%{__struct__: struct, reason: :closed}),
    do:
      "the connection to the Codex API closed before any response (#{inspect(struct)} :closed). " <>
        "This is usually a transient network/endpoint issue — try again. See ~/.catalyst/debug/latest.log for the request."

  defp stream_error_message(reason), do: "stream error: #{inspect(reason)}"

  defp handle_chunk({:status, status}, acc), do: %{acc | status: status}
  defp handle_chunk({:headers, _headers}, acc), do: acc

  defp handle_chunk({:data, chunk}, %{status: 200} = acc) do
    {buffer, events} = SSE.feed(acc.buffer, chunk)
    parser = Enum.reduce(events, acc.parser, fn ev, p -> StreamParser.handle(p, ev, acc.sink) end)
    %{acc | buffer: buffer, parser: parser}
  end

  # Non-200: collect the body so we can report the error.
  defp handle_chunk({:data, chunk}, acc), do: %{acc | error_body: acc.error_body <> chunk}

  defp resolve_url(model) do
    base = (model.base_url || @default_base) |> String.trim() |> String.replace_trailing("/", "")

    cond do
      base == "" -> @default_base <> "/codex/responses"
      String.ends_with?(base, "/codex/responses") -> base
      String.ends_with?(base, "/codex") -> base <> "/responses"
      true -> base <> "/codex/responses"
    end
  end

  defp error_assistant(model, message) do
    Logger.warning("[openai-codex] #{message}")

    %Message.Assistant{
      content: [%Content.Text{text: message}],
      api: model.api,
      provider: model.provider,
      model: model.id,
      stop_reason: :error,
      error_message: message,
      timestamp: Message.now()
    }
  end

  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
