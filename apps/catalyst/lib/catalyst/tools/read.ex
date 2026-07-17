defmodule Catalyst.Tools.Read do
  @moduledoc "Read a file's contents, with optional line offset/limit and head-truncation."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Paths, Truncate}

  @impl true
  def name, do: "read"

  @impl true
  def description,
    do:
      "Read a file's contents. Supports text files and images (jpg, png, gif, webp) — " <>
        "images are returned as attachments. Optional 1-indexed `offset` and `limit` " <>
        "select a line range. Output is truncated to 2000 lines or 50KB."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "File path (relative to cwd or absolute)"
        },
        "offset" => %{
          "type" => "integer",
          "description" => "1-indexed start line",
          "minimum" => 1
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum lines to read",
          "minimum" => 1
        }
      },
      "required" => ["path"]
    }
  end

  # Files up to this size are read whole (exact line totals in the notice);
  # larger ones are streamed in fixed-size chunks with bounded accumulation so
  # a huge file can never be loaded into memory just to return a 50KB slice.
  @max_in_memory 16 * 1024 * 1024
  @stream_chunk_size 64 * 1024

  # Images above this raw size are described, not attached (no resizing
  # support — PI resizes to 2000×2000; we cap instead).
  @max_image_bytes 5 * 1024 * 1024

  @impl true
  def execute(%{"path" => path} = args, ctx) do
    abs = Paths.resolve(path, ctx.cwd)
    %File.Stat{size: size} = File.stat!(abs)

    cond do
      mime = image_mime_type(abs) ->
        read_image(abs, size, mime)

      binary_file?(abs) ->
        raise "#{path} appears to be a binary file (#{size} bytes); not returning its contents"

      size <= @max_in_memory ->
        read_whole(abs, args)

      true ->
        read_streamed(abs, args, size)
    end
  end

  # PI parity: images come back as an attachment (base64 content block) with a
  # text note; oversized ones are described instead of inlined.
  defp read_image(abs, size, mime) do
    case size > @max_image_bytes do
      true ->
        result(
          "Read image file [#{mime}]\n[Image omitted: #{size} bytes exceeds the " <>
            "#{@max_image_bytes}-byte inline limit.]",
          %{path: abs, mime_type: mime, bytes: size, omitted: true}
        )

      false ->
        data = abs |> File.read!() |> Base.encode64()

        %{
          content: [
            %Catalyst.Content.Text{text: "Read image file [#{mime}]"},
            %Catalyst.Content.Image{data: data, mime_type: mime}
          ],
          details: %{path: abs, mime_type: mime, bytes: size},
          terminate: false
        }
    end
  end

  # Magic-byte sniff for the image formats PI supports (jpg/png/gif/webp).
  defp image_mime_type(abs) do
    case File.open(abs, [:read, :binary], fn io -> IO.binread(io, 16) end) do
      {:ok, <<0xFF, 0xD8, 0xFF, _rest::binary>>} -> "image/jpeg"
      {:ok, <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>} -> "image/png"
      {:ok, <<"GIF8", _rest::binary>>} -> "image/gif"
      {:ok, <<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>} -> "image/webp"
      _other -> nil
    end
  end

  defp read_whole(abs, args) do
    lines = abs |> File.read!() |> Truncate.scrub_utf8() |> String.split("\n")
    total = logical_line_count(lines)
    start = max((args["offset"] || 1) - 1, 0)

    case start >= total do
      true ->
        result("offset #{start + 1} is beyond the end of the file (#{total} lines)", %{
          path: abs,
          file_lines: total,
          offset: start + 1
        })

      false ->
        requested_lines = requested_line_count(total, start, args["limit"])
        shown_lines = min(requested_lines, Truncate.default_max_lines())
        text = lines |> Enum.slice(start, shown_lines) |> Enum.join("\n")
        {out, info} = text |> Truncate.head() |> include_unjoined_lines(requested_lines)

        # `truncation` describes the requested slice; `file_lines` is the whole
        # file (already in memory, so counting is cheap).
        result(Truncate.notice(out, info, :head), %{
          path: abs,
          truncation: info,
          file_lines: total,
          offset: start + 1
        })
    end
  end

  # A single trailing newline terminates the last line; it does not open a
  # phantom empty line, so "a\nb\n" is 2 lines for offset/EOF purposes.
  defp logical_line_count([_single] = segments), do: length(segments)

  defp logical_line_count(segments) do
    case List.last(segments) do
      "" -> length(segments) - 1
      _ -> length(segments)
    end
  end

  # Streamed path: drop to the offset, accumulate at most the line/byte budget,
  # and stop reading. Totals are unknown (no full scan); the notice reports the
  # file size instead.
  defp read_streamed(abs, args, size) do
    start = max((args["offset"] || 1) - 1, 0)
    max_lines = min(args["limit"] || Truncate.default_max_lines(), Truncate.default_max_lines())
    max_bytes = Truncate.default_max_bytes()

    %{acc: acc, lines: count} =
      abs
      |> File.stream!(@stream_chunk_size, [])
      |> Enum.reduce_while(stream_state(start, max_lines, max_bytes), &stream_chunk/2)

    case {count, start} do
      # Nothing collected because the offset skipped the whole file.
      {0, s} when s > 0 ->
        result("offset #{start + 1} is beyond the end of the file (file is #{size} bytes)", %{
          path: abs,
          file_bytes: size,
          lines_shown: 0,
          offset: start + 1
        })

      _ ->
        text = acc |> Enum.reverse() |> IO.iodata_to_binary() |> streamed_text()

        {out, _info} = Truncate.head(text)
        notice = "\n... [showing #{count} line(s) from line #{start + 1}; file is #{size} bytes]"

        result(out <> notice, %{
          path: abs,
          file_bytes: size,
          lines_shown: count,
          offset: start + 1
        })
    end
  end

  defp stream_state(skip, max_lines, max_bytes) do
    %{
      skip: skip,
      max_lines: max_lines,
      max_bytes: max_bytes,
      acc: [],
      bytes: 0,
      lines: 0,
      line_open?: false
    }
  end

  defp stream_chunk(chunk, %{skip: skip} = state) when skip > 0 do
    case skip_lines(chunk, state) do
      {<<>>, state} -> {:cont, state}
      {rest, state} -> collect_chunk(rest, state)
    end
  end

  defp stream_chunk(chunk, state), do: collect_chunk(chunk, state)

  defp skip_lines(chunk, %{skip: 0} = state), do: {chunk, state}
  defp skip_lines(<<>>, state), do: {<<>>, state}

  defp skip_lines(chunk, %{skip: skip} = state) do
    case :binary.match(chunk, "\n") do
      {index, 1} ->
        rest_start = index + 1
        rest = binary_part(chunk, rest_start, byte_size(chunk) - rest_start)
        skip_lines(rest, %{state | skip: skip - 1})

      :nomatch ->
        {<<>>, state}
    end
  end

  defp collect_chunk(<<>>, state), do: {:cont, state}

  defp collect_chunk(_chunk, %{bytes: bytes, max_bytes: max_bytes} = state)
       when bytes >= max_bytes,
       do: {:halt, state}

  defp collect_chunk(_chunk, %{lines: lines, max_lines: max_lines, line_open?: false} = state)
       when lines >= max_lines,
       do: {:halt, state}

  defp collect_chunk(chunk, state) do
    case :binary.match(chunk, "\n") do
      {index, 1} ->
        line_end = index + 1
        segment = binary_part(chunk, 0, line_end)
        rest = binary_part(chunk, line_end, byte_size(chunk) - line_end)

        case append_segment(segment, state) do
          {:cont, state} -> collect_chunk(rest, %{state | line_open?: false})
          {:halt, state} -> {:halt, state}
        end

      :nomatch ->
        append_segment(chunk, state)
    end
  end

  defp append_segment(<<>>, state), do: {:cont, state}

  defp append_segment(segment, state) do
    remaining = state.max_bytes - state.bytes
    take = min(byte_size(segment), remaining)
    data = binary_part(segment, 0, take)
    state = state |> open_line() |> append_data(data)

    case take == byte_size(segment) do
      true -> {:cont, state}
      false -> {:halt, state}
    end
  end

  defp open_line(%{line_open?: true} = state), do: state
  defp open_line(state), do: %{state | line_open?: true, lines: state.lines + 1}

  defp append_data(state, data) do
    %{state | acc: [data | state.acc], bytes: state.bytes + byte_size(data)}
  end

  defp streamed_text(text) do
    text
    |> String.trim_trailing("\n")
    |> Truncate.scrub_utf8()
  end

  defp requested_line_count(total, start, nil), do: total - start
  defp requested_line_count(total, start, limit), do: min(total - start, limit)

  defp include_unjoined_lines({out, info}, requested_lines)
       when requested_lines > info.total_lines do
    by =
      case info.truncated_by do
        :bytes -> :bytes
        _ -> :lines
      end

    {out, %{info | truncated: true, truncated_by: by, total_lines: requested_lines}}
  end

  defp include_unjoined_lines(result, _requested_lines), do: result

  # Null byte in the first 8KB — the same heuristic git/grep use. Reads only
  # the sniff window, never the whole file.
  defp binary_file?(abs) do
    case :file.open(abs, [:read, :raw, :binary]) do
      {:ok, io} ->
        head =
          case :file.read(io, 8 * 1024) do
            {:ok, data} -> data
            _ -> <<>>
          end

        :file.close(io)
        :binary.match(head, <<0>>) != :nomatch

      {:error, _} ->
        false
    end
  end
end
