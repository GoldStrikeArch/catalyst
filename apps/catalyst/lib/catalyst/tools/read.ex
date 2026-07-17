defmodule Catalyst.Tools.Read do
  @moduledoc "Read a file's contents, with optional line offset/limit and head-truncation."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Paths, Truncate}

  @impl true
  def name, do: "read"

  @impl true
  def description,
    do:
      "Read a file's contents. Optional 1-indexed `offset` and `limit` select a line range. " <>
        "Output is truncated to 2000 lines or 50KB."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "File path (relative to cwd or absolute)"
        },
        "offset" => %{"type" => "integer", "description" => "1-indexed start line"},
        "limit" => %{"type" => "integer", "description" => "Maximum lines to read"}
      },
      "required" => ["path"]
    }
  end

  # Files up to this size are read whole (exact line totals in the notice);
  # larger ones are streamed line-by-line with bounded accumulation so a huge
  # file can never be loaded into memory just to return a 50KB slice.
  @max_in_memory 16 * 1024 * 1024

  @impl true
  def execute(%{"path" => path} = args, ctx) do
    abs = Paths.resolve(path, ctx.cwd)
    %File.Stat{size: size} = File.stat!(abs)

    if binary_file?(abs) do
      raise "#{path} appears to be a binary file (#{size} bytes); not returning its contents"
    end

    case size <= @max_in_memory do
      true -> read_whole(abs, args)
      false -> read_streamed(abs, args, size)
    end
  end

  defp read_whole(abs, args) do
    text =
      abs
      |> File.read!()
      |> Truncate.scrub_utf8()
      |> String.split("\n")
      |> slice(args["offset"], args["limit"])
      |> Enum.join("\n")

    {out, info} = Truncate.head(text)
    result(Truncate.notice(out, info, :head), %{path: abs, truncation: info})
  end

  # Streamed path: drop to the offset, accumulate at most the line/byte budget,
  # and stop reading. Totals are unknown (no full scan); the notice reports the
  # file size instead. (A single line longer than the budget is still buffered
  # by line-mode reads; the binary sniff above catches the usual such files.)
  defp read_streamed(abs, args, size) do
    start = max((args["offset"] || 1) - 1, 0)
    max_lines = min(args["limit"] || Truncate.default_max_lines(), Truncate.default_max_lines())
    max_bytes = Truncate.default_max_bytes()

    {lines, count, _bytes} =
      abs
      |> File.stream!()
      |> Stream.drop(start)
      |> Enum.reduce_while({[], 0, 0}, fn line, {acc, count, bytes} ->
        case count < max_lines and bytes < max_bytes do
          true -> {:cont, {[line | acc], count + 1, bytes + byte_size(line)}}
          false -> {:halt, {acc, count, bytes}}
        end
      end)

    text =
      lines
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> String.trim_trailing("\n")
      |> Truncate.scrub_utf8()

    {out, _info} = Truncate.head(text)
    notice = "\n... [showing #{count} line(s) from line #{start + 1}; file is #{size} bytes]"

    result(out <> notice, %{
      path: abs,
      file_bytes: size,
      lines_shown: count,
      offset: start + 1
    })
  end

  defp slice(lines, offset, limit) do
    start = max((offset || 1) - 1, 0)
    dropped = Enum.drop(lines, start)
    if limit, do: Enum.take(dropped, limit), else: dropped
  end

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
