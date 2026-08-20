defmodule Catalyst.LLM.GrokSubscription.Transport do
  @moduledoc "Finch/SSE transport for one Grok subscription Chat Completions request."

  alias Catalyst.LLM.GrokSubscription.StreamParser
  alias Catalyst.LLM.SSE

  @receive_timeout 600_000
  @max_error_body 65_536

  @type result ::
          {:ok, StreamParser.t()}
          | {:unauthorized, binary()}
          | {:http_error, non_neg_integer() | nil, binary()}
          | {:error, term()}

  @doc "POST and incrementally reduce a streaming Chat Completions response."
  @spec stream(String.t(), [{String.t(), String.t()}], map(), Catalyst.LLM.Provider.sink()) ::
          result()
  def stream(url, headers, body, sink) do
    request = Finch.build(:post, url, headers, Jason.encode!(body))

    acc = %{
      status: nil,
      buffer: "",
      parser: StreamParser.new(),
      sink: sink,
      error_body: ""
    }

    request
    |> Finch.stream(Catalyst.Finch, acc, &handle_chunk/2, receive_timeout: @receive_timeout)
    |> result()
  end

  defp handle_chunk({:status, status}, acc), do: %{acc | status: status}
  defp handle_chunk({:headers, _headers}, acc), do: acc

  defp handle_chunk({:data, chunk}, %{status: 200} = acc) do
    {buffer, events} = SSE.feed(acc.buffer, chunk)
    parser = Enum.reduce(events, acc.parser, &StreamParser.handle(&2, &1, acc.sink))
    %{acc | buffer: buffer, parser: parser}
  end

  defp handle_chunk({:data, chunk}, acc),
    do: %{acc | error_body: append_bounded(acc.error_body, chunk)}

  defp result({:ok, %{status: 200, parser: parser}}), do: {:ok, parser}

  defp result({:ok, %{status: 401, error_body: body}}), do: {:unauthorized, body}

  defp result({:ok, %{status: status, error_body: body}}),
    do: {:http_error, status, body}

  defp result({:error, reason, %{status: 200, parser: parser, sink: sink}}),
    do: {:ok, StreamParser.fail(parser, {:transport, reason}, sink)}

  defp result({:error, reason, _partial}), do: {:error, reason}

  defp append_bounded(buffer, chunk) do
    remaining = @max_error_body - byte_size(buffer)

    case remaining > 0 do
      true -> buffer <> binary_part(chunk, 0, min(byte_size(chunk), remaining))
      false -> buffer
    end
  end
end
