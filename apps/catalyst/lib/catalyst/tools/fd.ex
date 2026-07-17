defmodule Catalyst.Tools.Fd do
  @moduledoc "Filename search via fd (`find` tool). Glob mode; respects .gitignore."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Binaries, Exec, Paths, Truncate}

  @default_limit 1000

  @impl true
  def name, do: "find"

  @impl true
  def description,
    do: "Find files by glob pattern with fd (respects .gitignore). Returns matching paths."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Glob pattern, e.g. '*.ex' or '**/*.json'"
        },
        "path" => %{"type" => "string", "description" => "Directory to search (default: cwd)"},
        "limit" => %{"type" => "integer", "description" => "Max results (default: 1000)"}
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = args, ctx) do
    fd = Binaries.path!(:fd)
    target = Paths.resolve(args["path"] || ".", ctx.cwd)
    limit = args["limit"] || @default_limit

    fd_args = ["--color", "never", "--hidden", "--glob", pattern, target]

    case Exec.collect(fd, fd_args, cwd: ctx.cwd) do
      {:ok, %{out: out, status: status}} when status in [0, 1] ->
        results = String.split(out, "\n", trim: true)
        limited? = length(results) > limit
        shown = Enum.take(results, limit)
        text = if shown == [], do: "No files found.", else: Enum.join(shown, "\n")
        {body, info} = Truncate.head(text)

        result(body, %{
          result_count: length(shown),
          result_limit_reached: limited?,
          truncation: info
        })

      {:ok, %{out: out, status: status}} ->
        raise "fd error (status #{status}): #{String.slice(out, 0, 200)}"

      {:error, reason} ->
        raise "fd failed: #{inspect(reason)}"
    end
  end
end
