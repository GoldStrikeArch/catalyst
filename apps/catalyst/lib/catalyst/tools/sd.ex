defmodule Catalyst.Tools.Sd do
  @moduledoc "Find-and-replace in a file via sd (`replace` tool). In-place; regex or string mode."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Binaries, Diff, Exec, Paths, Truncate}

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "replace"

  @impl true
  def description,
    do:
      "Find-and-replace text in a file with sd (in place). Pattern is a regex " <>
        "unless `string_mode: true` (literal). Capture groups use $1, $2, …"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Find pattern (regex, or literal with string_mode)"
        },
        "replacement" => %{"type" => "string", "description" => "Replacement text"},
        "path" => %{"type" => "string", "description" => "File to edit in place"},
        "string_mode" => %{
          "type" => "boolean",
          "description" => "Treat pattern as a literal string (default: false)"
        }
      },
      "required" => ["pattern", "replacement", "path"]
    }
  end

  @impl true
  def execute(%{"pattern" => pattern, "replacement" => replacement, "path" => path} = args, ctx) do
    sd = Binaries.path!(:sd)
    abs = Paths.resolve(path, ctx.cwd)
    flags = if args["string_mode"], do: ["--string-mode"], else: []
    sd_args = flags ++ ["--", pattern, replacement, abs]
    original = File.read(abs)

    case Exec.collect(sd, sd_args, cwd: ctx.cwd) do
      {:ok, %{status: 0}} ->
        describe(original, abs, pattern)

      {:ok, %{out: out, status: status}} ->
        raise "sd error (status #{status}): #{String.slice(out, 0, 200)}"

      {:error, reason} ->
        raise "sd failed: #{inspect(reason)}"
    end
  end

  # sd exits 0 even when the pattern matched nothing; for a file we could read
  # beforehand, an empty diff means no occurrences — not a successful replace.
  defp describe({:ok, _} = original, abs, pattern) do
    case diff_against(original, abs) do
      "" ->
        result("No occurrences of #{inspect(pattern)} found in #{abs}", %{
          path: abs,
          matched: false
        })

      diff ->
        result(
          String.trim_trailing(
            "Replaced occurrences of #{inspect(pattern)} in #{abs}\n\n" <> diff
          ),
          %{path: abs, diff: diff, matched: true}
        )
    end
  end

  defp describe({:error, _unreadable_before}, abs, pattern) do
    result("Replaced occurrences of #{inspect(pattern)} in #{abs}", %{path: abs, diff: ""})
  end

  # sd edits in place, so diff the pre-read contents against the file after.
  # Scrubbed + capped: file bytes may be invalid UTF-8 (JSON-encoding the
  # transcript would crash) and a huge diff would blow the transcript budget.
  defp diff_against({:ok, original}, abs) do
    case File.read(abs) do
      {:ok, updated} ->
        {diff, info} =
          original |> Diff.unified(updated) |> Truncate.scrub_utf8() |> Truncate.head()

        Truncate.notice(diff, info, :head)

      _ ->
        ""
    end
  end
end
