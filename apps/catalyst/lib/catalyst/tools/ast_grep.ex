defmodule Catalyst.Tools.AstGrep do
  @moduledoc """
  Structural code search/rewrite via ast-grep (tree-sitter). Without `rewrite`
  it searches and returns matches as `file:line: text`; with `rewrite` it applies
  the rewrite in place across the target.
  """
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Binaries, Exec, Paths, Truncate}

  # ast-grep has no match limit or output cap of its own; bound the child's
  # stdout so a broad pattern over a big tree can't be accumulated unboundedly
  # (same rationale and size as ripgrep's cap).
  @max_output_bytes 8 * 1024 * 1024

  @impl true
  # Can mutate (rewrite mode), so serialize relative to other file-touching tools.
  def execution_mode, do: :sequential

  @impl true
  def name, do: "ast_grep"

  @impl true
  def description,
    do:
      "Structural code search/rewrite using ast-grep (tree-sitter). Provide a " <>
        "`pattern` and `lang` (e.g. 'elixir', 'rust', 'tsx'). Without `rewrite`, " <>
        "returns matches; with `rewrite`, applies it in place using $VAR metavariables."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "ast-grep pattern, with $VAR / $$$ metavariables"
        },
        "lang" => %{
          "type" => "string",
          "description" => "Language id, e.g. 'elixir', 'rust', 'python', 'tsx'"
        },
        "path" => %{
          "type" => "string",
          "description" => "File or directory to search (default: cwd)"
        },
        "rewrite" => %{
          "type" => "string",
          "description" => "If set, rewrite matches to this (in place)"
        }
      },
      "required" => ["pattern", "lang"]
    }
  end

  @impl true
  def execute(%{"pattern" => pattern, "lang" => lang} = args, ctx) do
    ag = Binaries.path!(:ast_grep)
    target = Paths.resolve(args["path"] || ".", ctx.cwd)

    case args["rewrite"] do
      nil -> search(ag, pattern, lang, target, ctx)
      rewrite -> rewrite(ag, pattern, lang, rewrite, target, ctx)
    end
  end

  defp search(ag, pattern, lang, target, ctx) do
    ag_args = ["run", "--pattern", pattern, "--lang", lang, "--json=stream", target]

    res =
      Exec.collect!("ast-grep", ag, ag_args,
        cwd: ctx.cwd,
        max_output_bytes: @max_output_bytes,
        ok_statuses: [0, 1]
      )

    capped? = Map.get(res, :truncated, false)
    matches = parse_matches(res.out)

    text =
      case matches do
        [] -> "No matches."
        matches -> Enum.join(matches, "\n")
      end

    {body, info} = Truncate.listing(text, limited?: false, limit: 0, total: 0, noun: "matches")

    body =
      body
      |> Exec.append_capped_notice(capped?, @max_output_bytes, "narrow the pattern or path")

    result(body, %{
      match_count: length(matches),
      output_capped: capped?,
      truncation: info
    })
  end

  defp rewrite(ag, pattern, lang, rewrite, target, ctx) do
    ag_args =
      ["run", "--pattern", pattern, "--rewrite", rewrite, "--lang", lang, "--update-all", target]

    # `--update-all` exits 1 with NO output when the pattern matched nothing —
    # the same "no matches" case search reports, not an error. Status 1 WITH
    # output is a real failure.
    case Exec.collect!("ast-grep rewrite", ag, ag_args, cwd: ctx.cwd, ok_statuses: [0, 1]) do
      %{status: 0, out: out} ->
        summary = out |> String.trim() |> default_if_blank("Rewrite applied.")
        result(summary, %{rewrote: true})

      %{status: 1, out: out} ->
        case String.trim(out) do
          "" -> result("No matches; nothing rewritten.", %{rewrote: false})
          err -> raise "ast-grep rewrite error (status 1): #{String.slice(err, 0, 200)}"
        end
    end
  end

  defp parse_matches(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&decode_match/1)
  end

  defp decode_match(line) do
    case Jason.decode(line) do
      {:ok, %{"file" => file} = m} ->
        # ast-grep reports 0-indexed lines; display 1-indexed.
        line_no = get_in(m, ["range", "start", "line"]) || 0
        text = m |> Map.get("lines", "") |> to_string() |> String.split("\n") |> List.first()
        ["#{file}:#{line_no + 1}: #{text}"]

      _ ->
        []
    end
  end

  defp default_if_blank("", default), do: default
  defp default_if_blank(str, _default), do: str
end
