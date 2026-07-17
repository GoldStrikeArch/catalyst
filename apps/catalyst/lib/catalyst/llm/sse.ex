defmodule Catalyst.LLM.SSE do
  @moduledoc """
  Incremental Server-Sent-Events decoder for the streaming HTTP body.

  `feed/2` takes the carry-over buffer and a new chunk and returns
  `{new_buffer, decoded_events}` — each event is the JSON-decoded `data:` payload
  (the OpenAI Responses API puts the event `type` inside the JSON). Frames split
  on a blank line; partial frames are carried in the buffer. `[DONE]` is ignored
  and malformed JSON frames are dropped (logged at debug).

  The buffer is opaque: start with `""` and thread the returned buffer back into
  the next call. Only the bytes around the new chunk are scanned for frame
  boundaries (never the whole carried frame again), so a large frame arriving in
  many small chunks costs O(frame) overall, not O(frame²). CRLF is normalized
  per extracted frame, not across the buffer.
  """

  require Logger

  # A frame ends on a blank line: any LF/CRLF pairing of the two line breaks.
  @boundaries ["\n\n", "\r\n\r\n", "\n\r\n", "\r\n\n"]
  # The longest boundary is 4 bytes; if it straddles the old/new edge, at most
  # 3 of its bytes were already in the carried buffer.
  @boundary_overlap 3
  @min_boundary 2

  @doc """
  Feed one body chunk, returning `{new_buffer, decoded_events}`.

  Pass `""` as the initial buffer and thread the returned buffer through
  subsequent calls; any trailing partial frame is carried over un-normalized.
  """
  @spec feed(binary(), binary()) :: {binary(), [map()]}
  def feed(buffer, chunk) do
    scan_from = max(byte_size(buffer) - @boundary_overlap, 0)
    extract_frames(buffer <> chunk, scan_from, [])
  end

  # Pull complete frames off the front of `buf`, scanning for a boundary only
  # from `from` (the previous call already proved everything before it is
  # boundary-free).
  defp extract_frames(buf, from, acc) when byte_size(buf) - from < @min_boundary,
    do: {buf, Enum.reverse(acc)}

  defp extract_frames(buf, from, acc) do
    case :binary.match(buf, @boundaries, scope: {from, byte_size(buf) - from}) do
      {pos, len} ->
        frame = binary_part(buf, 0, pos)
        rest = binary_part(buf, pos + len, byte_size(buf) - pos - len)
        extract_frames(rest, 0, Enum.reverse(parse_frame(frame), acc))

      :nomatch ->
        {buf, Enum.reverse(acc)}
    end
  end

  defp parse_frame(frame) do
    frame
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.flat_map(&data_line/1)
    |> Enum.join("\n")
    |> decode_payload()
  end

  # Per the SSE spec, strip at most ONE leading space after the colon.
  defp data_line("data: " <> value), do: [value]
  defp data_line("data:" <> value), do: [value]
  defp data_line(_line), do: []

  defp decode_payload(""), do: []
  defp decode_payload("[DONE]"), do: []

  defp decode_payload(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        [map]

      {:ok, _non_object} ->
        Logger.debug(fn -> "[sse] dropping non-object frame: #{String.slice(json, 0, 200)}" end)
        []

      {:error, reason} ->
        Logger.debug(fn ->
          "[sse] dropping malformed JSON frame (#{inspect(reason)}): #{String.slice(json, 0, 200)}"
        end)

        []
    end
  end
end
