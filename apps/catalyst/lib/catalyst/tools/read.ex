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

  @impl true
  def execute(%{"path" => path} = args, ctx) do
    abs = Paths.resolve(path, ctx.cwd)
    content = File.read!(abs)

    if binary_content?(content) do
      raise "#{path} appears to be a binary file (#{byte_size(content)} bytes); not returning its contents"
    end

    text =
      content
      |> Truncate.scrub_utf8()
      |> String.split("\n")
      |> slice(args["offset"], args["limit"])
      |> Enum.join("\n")

    {out, info} = Truncate.head(text)
    result(Truncate.notice(out, info, :head), %{path: abs, truncation: info})
  end

  defp slice(lines, offset, limit) do
    start = max((offset || 1) - 1, 0)
    dropped = Enum.drop(lines, start)
    if limit, do: Enum.take(dropped, limit), else: dropped
  end

  # Null byte in the first 8KB — the same heuristic git/grep use.
  defp binary_content?(bin) do
    head = binary_part(bin, 0, min(byte_size(bin), 8 * 1024))
    :binary.match(head, <<0>>) != :nomatch
  end
end
