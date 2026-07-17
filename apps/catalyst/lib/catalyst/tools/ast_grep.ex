defmodule Catalyst.Tools.AstGrep do
  @moduledoc """
  Structural code search/rewrite via ast-grep (tree-sitter). Without `rewrite`
  it searches and returns matches as `file:line: text`; with `rewrite` it applies
  the rewrite in place across the target.
  """
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Binaries, Exec, Paths, Truncate}

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
        "pattern" => %{"type" => "string", "description" => "ast-grep pattern, with $VAR / $$$ metavariables"},
        "lang" => %{"type" => "string", "description" => "Language id, e.g. 'elixir', 'rust', 'python', 'tsx'"},
        "path" => %{"type" => "string", "description" => "File or directory to search (default: cwd)"},
        "rewrite" => %{"type" => "string", "description" => "If set, rewrite matches to this (in place)"}
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

    case Exec.collect(ag, ag_args, cwd: ctx.cwd) do
      {:ok, %{out: out, status: status}} when status in [0, 1] ->
        matches = parse_matches(out)
        text = if matches == [], do: "No matches.", else: Enum.join(matches, "\n")
        {body, info} = Truncate.head(text)
        result(body, %{match_count: length(matches), truncation: info})

      {:ok, %{out: out, status: status}} ->
        raise "ast-grep error (status #{status}): #{String.slice(out, 0, 300)}"

      {:error, reason} ->
        raise "ast-grep failed: #{inspect(reason)}"
    end
  end

  defp rewrite(ag, pattern, lang, rewrite, target, ctx) do
    ag_args =
      ["run", "--pattern", pattern, "--rewrite", rewrite, "--lang", lang, "--update-all", target]

    case Exec.collect(ag, ag_args, cwd: ctx.cwd) do
      {:ok, %{out: out, status: 0}} ->
        summary = out |> String.trim() |> default_if_blank("Rewrite applied.")
        result(summary, %{rewrote: true})

      {:ok, %{out: out, status: status}} ->
        raise "ast-grep rewrite error (status #{status}): #{String.slice(out, 0, 300)}"

      {:error, reason} ->
        raise "ast-grep failed: #{inspect(reason)}"
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
