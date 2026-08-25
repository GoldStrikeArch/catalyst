defmodule Catalyst.LLM.OpenAICodex.Provider do
  @moduledoc """
  OpenAI Codex (ChatGPT subscription) provider over the Responses API at
  `https://chatgpt.com/backend-api/codex/responses`.

  Two transports (`opts[:transport]`, else `config :catalyst, :codex_transport`,
  default `:auto`):

    * `:websocket` — the Codex CLI's preferred transport (`prefer_websockets`
      in its model catalog): one `response.create` text frame per turn, events
      back as JSON frames. A bounded supervised cache owns sockets between
      turns/runs; ownership transfers to the run task while a response streams,
      and session termination, idle TTL, or capacity eviction closes it.
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
  alias Catalyst.Context.Tokens

  alias Catalyst.LLM.OpenAICodex.{
    ConnCache,
    Headers,
    Request,
    SSETransport,
    StreamParser,
    WebSocket
  }

  @default_base "https://chatgpt.com/backend-api"
  # TokenStore key for the ChatGPT OAuth credentials (single source).
  @auth_provider Catalyst.Auth.OpenAIOAuth.provider_id()

  @impl true
  @spec stream(
          Catalyst.Model.t(),
          Catalyst.LLM.Context.t(),
          keyword(),
          Catalyst.LLM.Provider.sink()
        ) :: {:ok, Message.Assistant.t()} | {:error, term()}
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
         "not authenticated (#{inspect(reason)}). Sign in to ChatGPT from the sign-in button " <>
           "(or run Catalyst.Auth.login_openai_codex/0)."}
    end
  end

  @doc """
  Pre-establish the session's websocket and upload the request prefix — the
  Codex CLI's warmup: a full `response.create` with `"generate": false`. The
  server completes without generating, and the first real turn then rides
  `previous_response_id`, uploading only the user's new message.

  Best-effort semantics: no-op when not authenticated, when a connection
  is already cached for the session, or on any failure (the first turn just
  does a normal full upload). Started by `Session.RunContext.start_prewarm/1` in a
  supervised task; `context` must mirror what the next run would send
  (system prompt, transcript, live tools) or the continuation's body probe
  won't match and the warmup is wasted (never wrong — just wasted).
  """
  @spec prewarm(Catalyst.Model.t(), Catalyst.LLM.Context.t(), keyword()) :: :ok
  def prewarm(model, context, opts) do
    with {:ok, token, account_id} <- credentials(),
         session_id = opts[:session_id] || random_id(),
         url = resolve_url(model),
         false <- ConnCache.has?(session_id, url),
         base_body = Request.build(model, context, Keyword.put(opts, :session_id, session_id)),
         headers = Headers.websocket(token, account_id, session_id),
         {:ok, conn} <- WebSocket.connect(url, headers) do
      Debug.log(session_id, "codex.request", "ws prewarm model=#{model.id} (generate: false)")

      frame = base_body |> Map.put("generate", false) |> encode_frame()
      reducer = fn event, parser -> StreamParser.handle(parser, event, fn _ev -> :ok end) end

      case WebSocket.request(conn, frame, StreamParser.new(), reducer) do
        {:ok, conn, parser}
        when is_binary(parser.response_id) and parser.done and is_nil(parser.error) and
               parser.stop_reason == :stop ->
          continuation = %{
            response_id: parser.response_id,
            covered_count: length(context.messages),
            # `body_probe` already guards every non-message request option.
            # Keep the covered-prefix digest scoped to the semantic context so
            # it compares identically when a later request carries different
            # transport/runtime-only options.
            covered_hash: covered_hash(model, context, []),
            body_probe: Map.delete(base_body, "input")
          }

          ConnCache.stash(session_id, url, conn, continuation)
          Debug.log(session_id, "codex.response", "ws prewarm ok (#{parser.response_id})")
          :ok

        {:ok, conn, _parser_without_id} ->
          # Completed but unusable as a continuation anchor — keep the socket.
          ConnCache.stash(session_id, url, conn, nil)
          :ok

        {:error, reason, _parser, _emitted} ->
          Debug.log(session_id, "codex.error", "ws prewarm failed: #{inspect(reason)}")
          :ok
      end
    else
      _not_authenticated_or_cached_or_connect_failed -> :ok
    end
  end

  @doc "Release an idle websocket retained for `session_id`."
  @impl true
  @spec cleanup_session(String.t()) :: :ok
  def cleanup_session(session_id), do: ConnCache.drop(session_id)

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
    request_opts = Keyword.put(opts, :session_id, session_id)
    body_probe = Request.base(model, context, request_opts)

    req = %{
      model: model,
      body_probe: body_probe,
      context: context,
      sink: sink,
      token: token,
      account_id: account_id,
      session_id: session_id
    }

    case resolve_transport(opts) do
      :sse -> attempt_sse(model, full_body(req), sink, token, account_id, session_id)
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

  # Between requests the connection (and its continuation — the
  # connection-scoped previous_response_id state, the Codex CLI's delta-upload
  # mechanism) lives in `ConnCache`, keyed by session id, so it survives run
  # boundaries: turn 1 of the next prompt rides a delta too. While a request
  # streams, the run task owns the socket — aborting the run kills both.

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
    case ConnCache.checkout(session_id, url) do
      {:ok, conn, continuation} ->
        case WebSocket.open?(conn) do
          true ->
            {:ok, conn, true, continuation}

          false ->
            connect_ws(url, headers, session_id)
        end

      :none ->
        connect_ws(url, headers, session_id)
    end
  end

  defp connect_ws(url, headers, session_id) do
    Debug.log(session_id, "codex.request", "ws connect #{url}")

    case WebSocket.connect(url, headers) do
      {:ok, conn} ->
        # The upgrade response carries the catalog freshness signal.
        Catalyst.LLM.OpenAICodex.notice_models_etag(
          Headers.get(conn.resp_headers, "x-models-etag")
        )

        {:ok, conn, false, nil}

      {:error, _reason} = err ->
        err
    end
  end

  defp run_ws_request(conn, reused?, continuation, req) do
    {frame_body, delta?} = delta_body(continuation, req)
    frame = encode_frame(frame_body)

    Debug.log(
      req.session_id,
      "codex.request",
      "ws response.create model=#{req.model.id} reused=#{reused?} delta=#{delta?} " <>
        "body=#{frame |> Debug.scrub_image_payloads() |> Debug.truncate(3_000)}"
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

    case WebSocket.request(conn, frame, StreamParser.new(), reducer) do
      {:ok, conn, parser} ->
        assistant = StreamParser.finalize(parser, req.model)

        ConnCache.stash(
          req.session_id,
          resolve_url(req.model),
          conn,
          next_continuation(req, assistant)
        )

        case parser.error do
          nil -> Debug.log(req.session_id, "codex.response", "ws ok")
          error -> Debug.log(req.session_id, "codex.error", "ws server error: #{error}")
        end

        {:ok, assistant}

      {:error, reason, parser, _decoded} ->
        # The socket is already closed (WebSocket.fail/2); nothing to stash.
        ws_stream_error(reason, parser, :counters.get(delivered, 1), reused?, req)
    end
  end

  # Connection-scoped previous_response_id delta (what the Codex CLI does):
  # within one live socket, when nothing but the message tail changed since
  # the last completed response, upload only the new items. ANY other change —
  # new connection, model/instructions/tools/options change, rewritten or
  # compacted history, a prior error — falls back to the full input.
  defp delta_body(nil, req), do: {full_body(req), false}

  defp delta_body(cont, req) do
    messages = req.context.messages
    suffix = Enum.drop(messages, cont.covered_count)

    delta_ok? =
      is_binary(cont.response_id) and cont.response_id != "" and
        suffix != [] and
        cont.body_probe == req.body_probe and
        covered_hash(
          req.model,
          %{req.context | messages: Enum.take(messages, cont.covered_count)},
          []
        ) ==
          cont.covered_hash

    case delta_ok? do
      true ->
        frame =
          req.body_probe
          |> Map.put("input", Request.input_items(suffix, req.model))
          |> Map.put("previous_response_id", cont.response_id)

        {frame, true}

      false ->
        {full_body(req), false}
    end
  end

  # The next turn's context is this turn's messages + the assistant the server
  # just produced (the loop appends exactly this struct); the server's
  # connection state covers all of it. No continuation after a failed
  # response — the CLI resets on error too.
  defp next_continuation(
         req,
         %Message.Assistant{stop_reason: reason, error_message: nil, response_id: response_id} =
           assistant
       )
       when reason in [:stop, :tool_use] and is_binary(response_id) and response_id != "" do
    covered = req.context.messages ++ [assistant]

    %{
      response_id: assistant.response_id,
      covered_count: length(covered),
      covered_hash: covered_hash(req.model, %{req.context | messages: covered}, []),
      body_probe: req.body_probe
    }
  end

  defp next_continuation(_req, _assistant), do: nil

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

    attempt_sse(
      req.model,
      full_body(req),
      req.sink,
      req.token,
      req.account_id,
      req.session_id
    )
  end

  defp ws_failure(req, reason) do
    Debug.log(req.session_id, "codex.error", "websocket failed: #{inspect(reason)}")
    {:ok, error_assistant(req.model, "websocket error: #{inspect(reason)}")}
  end

  # ---- SSE transport ----------------------------------------------------------

  defp attempt_sse(model, body_map, sink, token, account_id, session_id) do
    url = resolve_url(model)
    headers = Headers.build(token, account_id, session_id)

    SSETransport.stream(url, headers, body_map, sink, session_id)
    |> handle_sse_result(model)
  end

  defp handle_sse_result({:ok, parser}, model),
    do: {:ok, StreamParser.finalize(parser, model)}

  defp handle_sse_result({:partial, parser}, model),
    do: {:ok, StreamParser.finalize(parser, model)}

  defp handle_sse_result({:unauthorized, body}, _model), do: {:unauthorized, body}

  defp handle_sse_result({:http_error, status, body}, model),
    do: {:ok, error_assistant(model, http_error(status, body))}

  defp handle_sse_result({:error, reason, _status}, model),
    do: {:ok, error_assistant(model, stream_error_message(reason))}

  defp stream_error_message(%{__struct__: struct, reason: :closed}),
    do:
      "the connection to the Codex API closed before any response (#{inspect(struct)} :closed). " <>
        "This is usually a transient network/endpoint issue — try again. See ~/.catalyst/debug/latest.log for the request."

  defp stream_error_message(reason), do: "stream error: #{inspect(reason)}"

  defp resolve_url(model) do
    base = (model.base_url || @default_base) |> String.trim() |> String.replace_trailing("/", "")

    cond do
      base == "" -> @default_base <> "/codex/responses"
      String.ends_with?(base, "/codex/responses") -> base
      String.ends_with?(base, "/codex") -> base <> "/responses"
      true -> base <> "/codex/responses"
    end
  end

  defp full_body(req) do
    Map.put(req.body_probe, "input", Request.input_items(req.context.messages, req.model))
  end

  defp encode_frame(body) do
    body
    |> Map.put("type", "response.create")
    |> Jason.encode!()
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

  defp random_id, do: Catalyst.Ids.hex(16)

  defp covered_hash(model, context, opts) do
    request_digest(model, context, opts)
  end

  defp request_digest(model, context, opts) do
    model
    |> Request.semantic_projection(context, opts)
    |> Tokens.projection_digest()
  end
end
