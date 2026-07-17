defmodule Catalyst.Tools.Edit do
  @moduledoc """
  Targeted string-replacement edits (PI's `edit`). Each `oldText` must occur
  exactly once in the original file; all edits are matched against the original
  and applied in order. (Fuzzy/Unicode-normalized matching is a later refinement;
  for structural edits use the `ast_grep` tool.)
  """
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.{AtomicWrite, Diff, Paths, Truncate}

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "edit"

  @impl true
  def description,
    do:
      "Edit a file by replacing exact text. Provide `edits`: a list of " <>
        "{oldText, newText}. Each oldText must appear exactly once."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "File path (relative to cwd or absolute)"
        },
        "edits" => %{
          "type" => "array",
          "description" => "List of replacements applied against the original file",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "oldText" => %{
                "type" => "string",
                "description" => "Exact text to find (must be unique)"
              },
              "newText" => %{"type" => "string", "description" => "Replacement text"}
            },
            "required" => ["oldText", "newText"]
          }
        }
      },
      "required" => ["path", "edits"]
    }
  end

  @impl true
  def execute(%{"path" => path} = args, ctx) do
    abs = Paths.resolve(path, ctx.cwd)
    original = File.read!(abs)
    edits = normalize_edits(args)

    updated = apply_edits(original, edits)
    AtomicWrite.write!(abs, updated)

    # The diff goes in the content too (not just details), so the model gets a
    # self-verification signal without re-reading the file. Scrub + cap it:
    # the file bytes may be invalid UTF-8 (JSON-encoding the transcript would
    # crash) and one huge line appears twice in a diff, blowing the budget.
    {diff, info} = original |> Diff.unified(updated) |> Truncate.scrub_utf8() |> Truncate.head()
    diff = Truncate.notice(diff, info, :head)

    result(String.trim_trailing("Applied #{length(edits)} edit(s) to #{abs}\n\n" <> diff), %{
      path: abs,
      bytes_before: byte_size(original),
      bytes_after: byte_size(updated),
      diff: diff
    })
  end

  # Accept the canonical `edits` array, or a single oldText/newText pair.
  defp normalize_edits(%{"edits" => edits}) when is_list(edits) do
    Enum.map(edits, fn e -> {Map.fetch!(e, "oldText"), Map.fetch!(e, "newText")} end)
  end

  defp normalize_edits(%{"oldText" => old, "newText" => new}), do: [{old, new}]

  # Every oldText is located in the ORIGINAL content (unique + non-overlapping),
  # then all replacements are spliced positionally — so one edit's newText can
  # never change what another edit matches.
  defp apply_edits(original, edits) do
    spans =
      edits
      |> Enum.map(fn {old, new} -> {locate(original, old), old, new} end)
      |> Enum.sort_by(fn {start, _old, _new} -> start end)

    check_overlaps!(spans)

    # Splice back-to-front so earlier positions stay valid.
    spans
    |> Enum.reverse()
    |> Enum.reduce(original, fn {start, old, new}, acc ->
      after_old = start + byte_size(old)
      binary_part(acc, 0, start) <> new <> binary_part(acc, after_old, byte_size(acc) - after_old)
    end)
  end

  defp locate(_content, ""), do: raise("edit failed: oldText must not be empty")

  defp locate(content, old) do
    case :binary.matches(content, old) do
      [{start, _len}] ->
        start

      [] ->
        raise "edit failed: oldText not found: #{inspect(String.slice(old, 0, 60))}"

      matches ->
        raise "edit failed: oldText occurs #{length(matches)} times (must be unique): " <>
                inspect(String.slice(old, 0, 60))
    end
  end

  defp check_overlaps!(spans) do
    spans
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [{s1, old1, _}, {s2, old2, _}] ->
      if s1 + byte_size(old1) > s2 do
        raise "edit failed: edits overlap: #{inspect(String.slice(old1, 0, 40))} and " <>
                inspect(String.slice(old2, 0, 40))
      end
    end)
  end
end
