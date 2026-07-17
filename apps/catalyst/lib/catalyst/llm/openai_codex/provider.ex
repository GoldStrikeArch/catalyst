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
    case credentials() do
      {:ok, token, account_id} ->
        do_stream(model, context, opts, sink, token, account_id)

      {:error, message} ->
        {:ok, error_assistant(model, message)}
    end
  end

  # The Codex backend requires the `chatgpt-account-id` header; without a
  # usable account id every request would 401 opaquely, so fail loudly here
  # (PI throws "Could not extract account ID" for the same reason).
  defp credentials do
    case TokenStore.get_access_token(@auth_provider) do
      {:ok, %{access: token, account_id: account_id}}
      when is_binary(account_id) and account_id != "" ->
        {:ok, token, account_id}

      {:ok, _no_account_id} ->
        {:error,
         "the access token carries no ChatGPT account id (required for the " <>
           "chatgpt-account-id header) — sign out and sign in again."}

      {:error, reason} ->
        {:error,
         "not authenticated (#{inspect(reason)}). Sign in to ChatGPT from the header " <>
           "(or run Catalyst.Auth.login_openai_codex/0)."}
    end
  end

  # One forced-refresh retry on 401: the token can be revoked/expired server-side
  # despite the local 60s freshness margin. A 401 means no SSE event has reached
  # the sink (non-200 bodies are collected, not parsed), so the retry is
  # invisible to the caller. 429/5xx retries live in attempt_sse (bounded,
  # honoring retry-after) — also invisible for the same reason.
  defp do_stream(model, context, opts, sink, token, account_id) do
    case attempt(model, context, opts, sink, token, account_id) do
      {:unauthorized, body} -> retry_unauthorized(model, context, opts, sink, body)
      {:ok, assistant} -> {:ok, assistant}
    end
  end

  defp retry_unauthorized(model, context, opts, sink, body) do
    :ok = TokenStore.invalidate(@auth_provider)

    case credentials() do
      {:ok, token, account_id} ->
        case attempt(model, context, opts, sink, token, account_id) do
          # A second 401 is terminal — report it like any other HTTP error.
          {:unauthorized, body2} -> {:ok, error_assistant(model, http_error(401, body2))}
          {:ok, assistant} -> {:ok, assistant}
        end

      {:error, message} ->
        {:ok, error_assistant(model, "#{http_error(401, body)} (#{message})")}
    end
  end

  defp http_error(status, body) do
    friendly_error(status, body) || "HTTP #{status}: #{String.slice(body, 0, 600)}"
  end

  # Port of PI's `parseErrorResponse`: a usage/rate limit surfaces as a plain
  # sentence with the plan and reset time instead of a raw JSON dump; any other
  # structured error at least gets its `message` field pulled out.
  defp friendly_error(status, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{} = err}} ->
        code = to_string(err["code"] || err["type"] || "")

        cond do
          status == 429 or
              Regex.match?(~r/usage_limit_reached|usage_not_included|rate_limit_exceeded/i, code) ->
            "You have hit your ChatGPT usage limit#{plan_suffix(err)}.#{resets_suffix(err)}"

          is_binary(err["message"]) and err["message"] != "" ->
            err["message"]

          true ->
            nil
        end

      _not_structured ->
        nil
    end
  end

  defp plan_suffix(%{"plan_type" => plan}) when is_binary(plan) and plan != "",
    do: " (#{String.downcase(plan)} plan)"

  defp plan_suffix(_err), do: ""

  defp resets_suffix(%{"resets_at" => secs}) when is_integer(secs) do
    mins = max(0, round((secs * 1000 - System.system_time(:millisecond)) / 60_000))
    " Try again in ~#{mins} min."
  end

  defp resets_suffix(_err), do: ""

  defp attempt(model, context, opts, sink, token, account_id) do
    session_id = opts[:session_id] || random_id()
    body = Request.build(model, context, Keyword.put(opts, :session_id, session_id))

    req = %{
      model: model,
      body: body,
      context: context,
      sink: sink,
      token: token,
      account_id: account_id,
      session_id: session_id
    }

    case resolve_transport(opts) do
      :sse -> attempt_sse(model, body, sink, token, account_id, session_id)
      :websocket -> attempt_ws(Map.put(req, :fallback?, false))
      :auto -> attempt_ws(Map.put(req, :fallback?, true))
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

  # The run task's process dictionary caches `{url, conn, continuation}`:
  # turn N+1 of the same run reuses turn N's socket, and the socket cannot
  # leak — it closes with the owning process when the run ends or is aborted.
  # `continuation` is the connection-scoped previous_response_id state (the
  # Codex CLI's delta-upload mechanism); it never outlives its connection.
  @ws_conn_key {__MODULE__, :ws_conn}

  defp attempt_ws(req) do
    url = resolve_url(req.model)
    headers = Headers.websocket(req.token, req.account_id, req.session_id)

    case checkout_ws(url, headers, req.session_id) do
      {:ok, conn, reused?, continuation} ->
        run_ws_request(conn, reused?, continuation, req)

      # A rejected upgrade carries the HTTP response — a 401 drives the same
      # forced-refresh retry as the SSE path.
      {:error, {:upgrade, 401, resp_body}} ->
        Debug.log(req.session_id, "codex.response", "ws upgrade 401")
        {:unauthorized, resp_body}

      {:error, reason} ->
        ws_failure(req, reason)
    end
  end

  defp checkout_ws(url, headers, session_id) do
    case Process.get(@ws_conn_key) do
      {^url, conn, continuation} ->
        case WebSocket.open?(conn) do
          true ->
            {:ok, conn, true, continuation}

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
      {:ok, conn} -> {:ok, conn, false, nil}
      {:error, _reason} = err -> err
    end
  end

  defp run_ws_request(conn, reused?, continuation, req) do
    {frame_body, delta?} = delta_body(continuation, req)

    Debug.log(
      req.session_id,
      "codex.request",
      "ws response.create model=#{req.model.id} reused=#{reused?} delta=#{delta?} " <>
        "body=#{Debug.truncate(Jason.encode!(frame_body), 3_000)}"
    )

    # Retry/fallback safety is judged by what the SINK saw, not by how many
    # frames were decoded: bookkeeping events (response.created,
    # output_item.added for messages, …) never reach the sink, so a socket
    # that died after only those can still be retried or fall back to SSE
    # without duplicating anything.
    delivered = :counters.new(1, [])

    counted_sink = fn ev ->
      :counters.add(delivered, 1, 1)
      req.sink.(ev)
    end

    reducer = fn event, parser -> StreamParser.handle(parser, event, counted_sink) end

    case WebSocket.request(conn, frame_body, StreamParser.new(), reducer) do
      {:ok, conn, parser} ->
        assistant = StreamParser.finalize(parser, req.model)
        Process.put(@ws_conn_key, {resolve_url(req.model), conn, next_continuation(req, assistant)})
        Debug.log(req.session_id, "codex.response", "ws ok")
        {:ok, assistant}

      {:error, reason, parser, _decoded} ->
        Process.delete(@ws_conn_key)
        ws_stream_error(reason, parser, :counters.get(delivered, 1), reused?, req)
    end
  end

  # Connection-scoped previous_response_id delta (what the Codex CLI does):
  # within one live socket, when nothing but the message tail changed since
  # the last completed response, upload only the new items. ANY other change —
  # new connection, model/instructions/tools/options change, rewritten or
  # compacted history, a prior error — falls back to the full input.
  defp delta_body(nil, req), do: {req.body, false}

  defp delta_body(cont, req) do
    messages = req.context.messages
    suffix = Enum.drop(messages, cont.covered_count)

    delta_ok? =
      is_binary(cont.response_id) and cont.response_id != "" and
        suffix != [] and
        cont.body_probe == Map.delete(req.body, "input") and
        :erlang.phash2(Enum.take(messages, cont.covered_count)) == cont.covered_hash

    if delta_ok? do
      frame =
        req.body
        |> Map.put("input", Request.input_items(suffix))
        |> Map.put("previous_response_id", cont.response_id)

      {frame, true}
    else
      {req.body, false}
    end
  end

  # The next turn's context is this turn's messages + the assistant the server
  # just produced (the loop appends exactly this struct); the server's
  # connection state covers all of it. No continuation after a failed
  # response — the CLI resets on error too.
  defp next_continuation(_req, %Message.Assistant{stop_reason: :error}), do: nil

  defp next_continuation(req, assistant) do
    covered = req.context.messages ++ [assistant]

    %{
      response_id: assistant.response_id,
      covered_count: length(covered),
      covered_hash: :erlang.phash2(covered),
      body_probe: Map.delete(req.body, "input")
    }
  end

  # Events already reached the sink — finalize the partial turn (same rule as
  # an SSE transport close after 200); a retry or fallback would duplicate them.
  defp ws_stream_error(reason, parser, delivered, _reused?, req) when delivered > 0 do
    Debug.log(req.session_id, "codex.error", "ws closed mid-response: #{inspect(reason)}")
    {:ok, StreamParser.finalize(parser, req.model)}
  end

  # A cached connection can go stale while tools ran — retry once on a fresh
  # socket before considering fallback.
  defp ws_stream_error(reason, _parser, 0, true = _reused?, req) do
    Debug.log(
      req.session_id,
      "codex.error",
      "ws reused conn failed (#{inspect(reason)}) — reconnecting"
    )

    attempt_ws(req)
  end

  defp ws_stream_error(reason, _parser, 0, false = _reused?, req) do
    ws_failure(req, reason)
  end

  defp ws_failure(%{fallback?: true} = req, reason) do
    Debug.log(
      req.session_id,
      "codex.error",
      "websocket failed before any event (#{inspect(reason)}) — falling back to SSE"
    )

    attempt_sse(req.model, req.body, req.sink, req.token, req.account_id, req.session_id)
  end

  defp ws_failure(req, reason) do
    Debug.log(req.session_id, "codex.error", "websocket failed: #{inspect(reason)}")
    {:ok, error_assistant(req.model, "websocket error: #{inspect(reason)}")}
  end

  # ---- SSE transport ------------------------------------------------------------

  # Bounded rate-limit/transient retries (PI's fetchWithRetry analog). Safe to
  # retry because non-200 bodies are collected, never parsed — no event has
  # reached the sink. A 429 without a retry-after header is a usage limit on
  # this backend (resets in minutes): surface the friendly message instead of
  # burning retries.
  @max_status_retries 2
  @max_retry_delay_ms 20_000
  @transient_statuses [500, 502, 503, 504]

  defp attempt_sse(model, body_map, sink, token, account_id, session_id, retries \\ 0) do
    url = resolve_url(model)
    headers = Headers.build(token, account_id, session_id)
    body = Jason.encode!(body_map)

    request = Finch.build(:post, url, headers, body)

    acc = %{
      status: nil,
      headers: [],
      buffer: "",
      parser: StreamParser.new(),
      sink: sink,
      error_body: ""
    }

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

      {:ok, %{status: status, error_body: body, headers: resp_headers}} ->
        Debug.log(
          session_id,
          "codex.response",
          "HTTP #{status} body=#{Debug.truncate(body, 1_500)}"
        )

        case retry_delay(status, resp_headers, retries) do
          {:retry, delay} ->
            Debug.log(
              session_id,
              "codex.response",
              "HTTP #{status} — retrying in #{delay}ms (#{retries + 1}/#{@max_status_retries})"
            )

            Process.sleep(delay)
            attempt_sse(model, body_map, sink, token, account_id, session_id, retries + 1)

          :no_retry ->
            {:ok, error_assistant(model, http_error(status, body))}
        end

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

  # 429: retry only on an explicit, short retry-after (a 429 without one is a
  # usage limit here — the friendly message beats burned retries). Transient
  # 5xx: retry with the advised delay or a linear backoff.
  defp retry_delay(status, headers, retries) when retries < @max_status_retries do
    advised = retry_after_ms(headers)

    cond do
      status == 429 and is_integer(advised) and advised <= @max_retry_delay_ms ->
        {:retry, advised}

      status in @transient_statuses ->
        {:retry, min(advised || 1_000 * (retries + 1), @max_retry_delay_ms)}

      true ->
        :no_retry
    end
  end

  defp retry_delay(_status, _headers, _retries), do: :no_retry

  defp retry_after_ms(headers) do
    cond do
      ms = parse_int(header(headers, "retry-after-ms")) -> ms
      secs = parse_int(header(headers, "retry-after")) -> secs * 1000
      true -> nil
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  defp parse_int(nil), do: nil

  defp parse_int(str) do
    case Integer.parse(String.trim(str)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp stream_error_message(%{__struct__: struct, reason: :closed}),
    do:
      "the connection to the Codex API closed before any response (#{inspect(struct)} :closed). " <>
        "This is usually a transient network/endpoint issue — try again. See ~/.catalyst/debug/latest.log for the request."

  defp stream_error_message(reason), do: "stream error: #{inspect(reason)}"

  defp handle_chunk({:status, status}, acc), do: %{acc | status: status}
  defp handle_chunk({:headers, headers}, acc), do: %{acc | headers: acc.headers ++ headers}

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
