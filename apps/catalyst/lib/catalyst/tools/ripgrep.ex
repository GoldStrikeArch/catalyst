defmodule Catalyst.Tools.Ripgrep do
  @moduledoc "Content search via ripgrep (`grep` tool). Respects .gitignore; returns `path:line: text`."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Binaries, Exec, Listing, Paths}

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
        "context" => %{
          "type" => "integer",
          "description" => "Lines of context around each match",
          "minimum" => 0,
          "maximum" => 100
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Max matches to return (default: 100)",
          "minimum" => 1,
          "maximum" => 10_000
        }
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = args, ctx) do
    rg = Binaries.path!(:rg)
    target = Paths.resolve(args["path"] || ".", ctx.cwd)
    limit = args["limit"] || @default_limit
    # rg has no global output cap; bound the child's stdout so a pathological
    # match set (huge lines, vendored blobs) can't be accumulated unboundedly.
    max_output_bytes = Listing.max_output_bytes()

    # --hidden un-hides dotfiles, so explicitly re-exclude .git internals.
    rg_args =
      ["--json", "--line-number", "--color=never", "--hidden", "--glob", "!.git/"] ++
        flags(args) ++ ["--", pattern, target]

    # rg: 0 = matches, 1 = no matches (both fine). 2 = an error occurred —
    # but rg exits 2 even when it also found matches (e.g. one unreadable
    # path among many). The stderr noise merged into stdout fails
    # Jason.decode and is dropped by decode_entry, so salvage whatever
    # parses with a note, and only raise when nothing parsed at all.
    %{out: out, status: status} =
      res =
      Exec.collect!("ripgrep", rg, rg_args,
        cwd: ctx.cwd,
        max_output_bytes: max_output_bytes,
        ok_statuses: [0, 1, 2]
      )

    capped? = Map.get(res, :truncated, false)
    entries = parse_entries(out)

    if status == 2 and entries == [] do
      raise "ripgrep error (status 2): #{String.slice(out, 0, 200)}"
    end

    total_matches = Enum.count(entries, &match?({:match, _}, &1))
    limited? = total_matches > limit
    shown = take_matches(entries, limit)

    text =
      case shown do
        [] -> "No matches."
        _ -> Enum.join(shown, "\n")
      end

    {text, details} =
      Listing.render(text,
        count: min(total_matches, limit),
        noun: "matches",
        limited?: limited?,
        limit: limit,
        total: known_total(total_matches, capped?),
        capped?: capped?,
        max_output_bytes: max_output_bytes,
        note: error_note(status == 2, out)
      )

    result(text, details)
  end

  # When the child's output was capped, total_matches is only a lower bound.
  defp known_total(total, false = _capped?), do: total
  defp known_total(_total, true = _capped?), do: :unknown

  # Status 2 with salvaged matches: tell the model the result set may be
  # incomplete. The sample is the first stderr line (non-JSON in rg's
  # otherwise JSON-lines output).
  defp error_note(false = _partial_error?, _out), do: nil

  defp error_note(true = _partial_error?, out) do
    sample =
      out
      |> String.split("\n", trim: true)
      |> Enum.find("", &match?({:error, _}, Jason.decode(&1)))
      |> String.slice(0, 200)

    "... [some paths could not be searched: #{sample}]"
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

  defp parse_entries(out), do: Listing.decode_json_lines(out, &decode_entry/1)

  # With --json, the lines requested via --context arrive as separate
  # "context" records; render them grep-style (`path-line- text`) and keep
  # them from counting toward the match limit.
  defp decode_entry(%{"type" => "match", "data" => data}), do: [{:match, format_line(data, ":")}]

  defp decode_entry(%{"type" => "context", "data" => data}),
    do: [{:context, format_line(data, "-")}]

  defp decode_entry(_other), do: []

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
