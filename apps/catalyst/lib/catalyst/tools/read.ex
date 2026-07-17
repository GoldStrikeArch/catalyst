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
        "path" => %{"type" => "string", "description" => "File path (relative to cwd or absolute)"},
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

    text =
      content
      |> String.split("\n")
      |> slice(args["offset"], args["limit"])
      |> Enum.join("\n")

    {out, info} = Truncate.head(text)
    result(out, %{path: abs, truncation: info})
  end

  defp slice(lines, offset, limit) do
    start = max((offset || 1) - 1, 0)
    dropped = Enum.drop(lines, start)
    if limit, do: Enum.take(dropped, limit), else: dropped
  end
end
