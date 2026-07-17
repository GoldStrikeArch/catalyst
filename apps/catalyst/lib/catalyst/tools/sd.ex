defmodule Catalyst.Tools.Sd do
  @moduledoc "Find-and-replace in a file via sd (`replace` tool). In-place; regex or string mode."
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{Binaries, Diff, Exec, Paths}

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

    flags =
      case args["string_mode"] do
        true -> ["--string-mode"]
        _ -> []
      end

    sd_args = flags ++ ["--", pattern, replacement, abs]
    original = File.read(abs)

    %{status: 0} = Exec.collect!("sd", sd, sd_args, cwd: ctx.cwd)
    describe(original, abs, pattern)
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
    result(
      "Replacement command completed for #{inspect(pattern)} in #{abs}, but the original " <>
        "content was unreadable, so whether anything changed is unknown.",
      %{path: abs, diff: "", matched: :unknown}
    )
  end

  # sd edits in place, so diff the pre-read contents against the file after.
  # Scrubbed + capped: file bytes may be invalid UTF-8 (JSON-encoding the
  # transcript would crash) and a huge diff would blow the transcript budget.
  defp diff_against({:ok, original}, abs) do
    case File.read(abs) do
      {:ok, updated} ->
        Diff.rendered(original, updated)

      _ ->
        ""
    end
  end
end
