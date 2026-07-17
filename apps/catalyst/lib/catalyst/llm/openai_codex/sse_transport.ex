defmodule Catalyst.LLM.OpenAICodex.SSETransport do
  @moduledoc """
  Streams one OpenAI Codex Responses request over server-sent events.

  The transport owns request construction, bounded non-success response bodies,
  retry timing, SSE framing, and incremental parser reduction. It returns
  transport-shaped tagged values; the provider turns those into assistants.
  """

  alias Catalyst.Debug
  alias Catalyst.LLM.SSE
  alias Catalyst.LLM.OpenAICodex.{BoundedBuffer, Headers, StreamParser}

  @receive_timeout 600_000
  @max_status_retries 2
  @max_retry_delay_ms 20_000
  @transient_statuses [500, 502, 503, 504]

  @type result ::
          {:ok, StreamParser.t()}
          | {:partial, StreamParser.t()}
          | {:unauthorized, binary()}
          | {:http_error, non_neg_integer() | nil, binary()}
          | {:error, term(), non_neg_integer() | nil}

  @doc "Stream a JSON-encodable request body through Finch."
  @spec stream(String.t(), [{String.t(), String.t()}], map(), (map() -> term()), String.t()) ::
          result()
  def stream(url, headers, body_map, sink, session_id) do
    do_stream(url, headers, body_map, sink, session_id, 0)
  end

  defp do_stream(url, headers, body_map, sink, session_id, retries) do
    {request, acc} = build(url, headers, body_map, sink, session_id)

    request
    |> Finch.stream(Catalyst.Finch, acc, &handle_chunk/2, receive_timeout: @receive_timeout)
    |> handle_sse_result(url, headers, body_map, sink, session_id, retries)
  end

  defp build(url, headers, body_map, sink, session_id) do
    body = Jason.encode!(body_map)

    Debug.log(
      session_id,
      "codex.request",
      "POST #{url} model=#{body_map["model"]} bytes=#{byte_size(body)} " <>
        "body=#{Debug.truncate(body, 3_000)}"
    )

    request = Finch.build(:post, url, headers, body)

    acc = %{
      status: nil,
      headers: [],
      buffer: "",
      parser: StreamParser.new(),
      sink: sink,
      error_body: BoundedBuffer.new()
    }

    {request, acc}
  end

  defp handle_sse_result(
         {:ok, %{status: 200, parser: parser, headers: response_headers}},
         _url,
         _headers,
         _body_map,
         _sink,
         session_id,
         _retries
       ) do
    Debug.log(session_id, "codex.response", "200 ok")
    Catalyst.LLM.OpenAICodex.notice_models_etag(Headers.get(response_headers, "x-models-etag"))
    {:ok, parser}
  end

  defp handle_sse_result(
         {:ok, %{status: 401} = acc},
         _url,
         _headers,
         _body_map,
         _sink,
         session_id,
         _retries
       ) do
    body = error_body(acc)
    Debug.log(session_id, "codex.response", "HTTP 401 body=#{Debug.truncate(body, 1_500)}")
    {:unauthorized, body}
  end

  defp handle_sse_result(
         {:ok, %{status: status, headers: response_headers} = acc},
         url,
         headers,
         body_map,
         sink,
         session_id,
         retries
       ) do
    body = error_body(acc)
    Debug.log(session_id, "codex.response", "HTTP #{status} body=#{Debug.truncate(body, 1_500)}")

    case retry_delay(status, response_headers, retries) do
      {:retry, delay} ->
        Debug.log(
          session_id,
          "codex.response",
          "HTTP #{status} — retrying in #{delay}ms (#{retries + 1}/#{@max_status_retries})"
        )

        Process.sleep(delay)
        do_stream(url, headers, body_map, sink, session_id, retries + 1)

      :no_retry ->
        {:http_error, status, body}
    end
  end

  defp handle_sse_result(
         {:error, reason, %{status: 200, parser: parser}},
         _url,
         _headers,
         _body_map,
         _sink,
         session_id,
         _retries
       ) do
    Debug.log(session_id, "codex.error", "stream closed mid-response: #{inspect(reason)}")
    {:partial, parser}
  end

  defp handle_sse_result(
         {:error, reason, partial},
         _url,
         _headers,
         _body_map,
         _sink,
         session_id,
         _retries
       ) do
    status = partial[:status]

    Debug.log(
      session_id,
      "codex.error",
      "transport error: #{inspect(reason)} (status=#{inspect(status)})"
    )

    {:error, reason, status}
  end

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
      milliseconds = parse_int(Headers.get(headers, "retry-after-ms")) -> milliseconds
      seconds = parse_int(Headers.get(headers, "retry-after")) -> seconds * 1_000
      true -> nil
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp handle_chunk({:status, status}, acc), do: %{acc | status: status}
  defp handle_chunk({:headers, headers}, acc), do: %{acc | headers: acc.headers ++ headers}

  defp handle_chunk({:data, chunk}, %{status: 200} = acc) do
    {buffer, events} = SSE.feed(acc.buffer, chunk)
    parser = Enum.reduce(events, acc.parser, &StreamParser.handle(&2, &1, acc.sink))
    %{acc | buffer: buffer, parser: parser}
  end

  defp handle_chunk({:data, chunk}, acc),
    do: %{acc | error_body: BoundedBuffer.append(acc.error_body, chunk)}

  defp error_body(acc), do: BoundedBuffer.to_binary(acc.error_body)
end
