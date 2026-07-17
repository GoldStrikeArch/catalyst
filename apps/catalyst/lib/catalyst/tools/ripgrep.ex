defmodule Catalyst.Tools.Ripgrep do
  @moduledoc "Content search via ripgrep (`grep` tool). Respects .gitignore; returns `path:line: text`."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Binaries, Exec, Paths, Truncate}

  @default_limit 100

  @impl true
  def name, do: "grep"

  @impl true
  def description,
    do:
      "Search file contents with ripgrep (respects .gitignore). Returns matching " <>
        "lines as `path:line: text`. Default limit 100 matches."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Regex (or literal, with `literal: true`) to search for"
        },
        "path" => %{
          "type" => "string",
          "description" => "Directory or file to search (default: cwd)"
        },
        "glob" => %{"type" => "string", "description" => "Filter files by glob, e.g. '*.ex'"},
        "ignoreCase" => %{
          "type" => "boolean",
          "description" => "Case-insensitive (default: false)"
        },
        "literal" => %{
          "type" => "boolean",
          "description" => "Treat pattern as a literal string (default: false)"
        },
        "context" => %{"type" => "integer", "description" => "Lines of context around each match"},
        "limit" => %{"type" => "integer", "description" => "Max matches to return (default: 100)"}
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = args, ctx) do
    rg = Binaries.path!(:rg)
    target = Paths.resolve(args["path"] || ".", ctx.cwd)
    limit = args["limit"] || @default_limit

    rg_args =
      ["--json", "--line-number", "--color=never", "--hidden"] ++
        flags(args) ++ ["--", pattern, target]

    case Exec.collect(rg, rg_args, cwd: ctx.cwd) do
      # rg: 0 = matches, 1 = no matches (both fine), >1 = real error
      {:ok, %{out: out, status: status}} when status in [0, 1] ->
        matches = parse_matches(out)
        limited? = length(matches) > limit
        shown = Enum.take(matches, limit)
        text = if shown == [], do: "No matches.", else: Enum.join(shown, "\n")
        {body, info} = Truncate.head(text)

        result(body, %{
          match_count: length(shown),
          match_limit_reached: limited?,
          truncation: info
        })

      {:ok, %{out: out, status: status}} ->
        raise "ripgrep error (status #{status}): #{String.slice(out, 0, 200)}"

      {:error, reason} ->
        raise "ripgrep failed: #{inspect(reason)}"
    end
  end

  defp flags(args) do
    []
    |> add_if(args["ignoreCase"], "--ignore-case")
    |> add_if(args["literal"], "--fixed-strings")
    |> add_kv(args["glob"], "--glob")
    |> add_kv(args["context"] && to_string(args["context"]), "--context")
  end

  defp add_if(acc, true, flag), do: acc ++ [flag]
  defp add_if(acc, _falsey, _flag), do: acc
  defp add_kv(acc, nil, _flag), do: acc
  defp add_kv(acc, value, flag), do: acc ++ [flag, value]

  defp parse_matches(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&decode_match/1)
  end

  defp decode_match(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "match", "data" => data}} ->
        path = get_in(data, ["path", "text"])
        n = data["line_number"]
        text = data |> get_in(["lines", "text"]) |> to_string() |> String.trim_trailing("\n")
        ["#{path}:#{n}: #{text}"]

      _ ->
        []
    end
  end
end
