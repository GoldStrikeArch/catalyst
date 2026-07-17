defmodule Catalyst.LLM.SSE do
  @moduledoc """
  Incremental Server-Sent-Events decoder for the streaming HTTP body.

  `feed/2` takes the carry-over buffer and a new chunk and returns
  `{new_buffer, decoded_events}` — each event is the JSON-decoded `data:` payload
  (the OpenAI Responses API puts the event `type` inside the JSON). Frames split
  on a blank line; partial frames are carried in the buffer. `[DONE]` is ignored.
  """

  @spec feed(binary(), binary()) :: {binary(), [map()]}
  def feed(buffer, chunk) do
    data = String.replace(buffer <> chunk, "\r\n", "\n")
    parts = String.split(data, "\n\n")
    {frames, [rest]} = Enum.split(parts, -1)
    {rest, Enum.flat_map(frames, &parse_frame/1)}
  end

  defp parse_frame(frame) do
    payload =
      frame
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", fn line ->
        line |> String.replace_prefix("data:", "") |> String.trim_leading()
      end)

    case payload do
      "" ->
        []

      "[DONE]" ->
        []

      json ->
        case Jason.decode(json) do
          {:ok, map} -> [map]
          _ -> []
        end
    end
  end
end
