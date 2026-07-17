defmodule Catalyst.Tools.Ripgrep do
  @moduledoc "Content search via ripgrep (`grep` tool). Respects .gitignore; returns `path:line: text`."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Binaries, Exec, Paths, Truncate}

  @default_limit 100
  # rg has no global output cap; bound the child's stdout so a pathological
  # match set (huge lines, vendored blobs) can't be accumulated unboundedly.
  @max_output_bytes 8 * 1024 * 1024

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

    # --hidden un-hides dotfiles, so explicitly re-exclude .git internals.
    rg_args =
      ["--json", "--line-number", "--color=never", "--hidden", "--glob", "!.git/"] ++
        flags(args) ++ ["--", pattern, target]

    case Exec.collect(rg, rg_args, cwd: ctx.cwd, max_output_bytes: @max_output_bytes) do
      # rg: 0 = matches, 1 = no matches (both fine), >1 = real error
      {:ok, %{out: out, status: status} = res} when status in [0, 1] ->
        capped? = Map.get(res, :truncated, false)
        entries = parse_entries(out)
        total_matches = Enum.count(entries, &match?({:match, _}, &1))
        limited? = total_matches > limit
        shown = take_matches(entries, limit)

        text =
          case shown do
            [] -> "No matches."
            _ -> Enum.join(shown, "\n")
          end

        {text, info} =
          Truncate.listing(text,
            limited?: limited?,
            limit: limit,
            total: known_total(total_matches, capped?),
            noun: "matches"
          )

        result(append_capped_notice(text, capped?), %{
          match_count: min(total_matches, limit),
          match_limit_reached: limited?,
          output_capped: capped?,
          truncation: info
        })

      {:ok, %{out: out, status: status}} ->
        raise "ripgrep error (status #{status}): #{String.slice(out, 0, 200)}"

      {:error, reason} ->
        raise "ripgrep failed: #{inspect(reason)}"
    end
  end

  # When the child's output was capped, total_matches is only a lower bound.
  defp known_total(total, false = _capped?), do: total
  defp known_total(_total, true = _capped?), do: :unknown

  defp append_capped_notice(text, false), do: text

  defp append_capped_notice(text, true),
    do:
      text <>
        "\n... [search output capped at #{div(@max_output_bytes, 1024 * 1024)}MB; " <>
        "narrow the pattern or path]"

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

  defp parse_entries(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&decode_entry/1)
  end

  # With --json, the lines requested via --context arrive as separate
  # "context" records; render them grep-style (`path-line- text`) and keep
  # them from counting toward the match limit.
  defp decode_entry(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "match", "data" => data}} -> [{:match, format_line(data, ":")}]
      {:ok, %{"type" => "context", "data" => data}} -> [{:context, format_line(data, "-")}]
      _ -> []
    end
  end

  defp format_line(data, sep) do
    path = get_in(data, ["path", "text"])
    n = data["line_number"]
    text = data |> get_in(["lines", "text"]) |> to_string() |> String.trim_trailing("\n")
    "#{path}#{sep}#{n}#{sep} #{text}"
  end

  # Keep entries in order until `limit` matches are included; context lines
  # ride along without counting.
  defp take_matches(entries, limit) do
    {lines, _count} =
      Enum.reduce_while(entries, {[], 0}, fn
        {:match, line}, {acc, n} when n < limit -> {:cont, {[line | acc], n + 1}}
        {:match, _line}, acc_n -> {:halt, acc_n}
        {:context, line}, {acc, n} -> {:cont, {[line | acc], n}}
      end)

    Enum.reverse(lines)
  end
end
