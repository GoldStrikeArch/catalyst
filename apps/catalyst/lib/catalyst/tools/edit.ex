defmodule Catalyst.Tools.Edit do
  @moduledoc """
  Targeted string-replacement edits (PI's `edit`, incl. its fuzzy matching).

  Each `oldText` is looked up exactly first; when an exact match is missing,
  a **fuzzy** pass normalizes both sides (NFKC, trailing whitespace stripped
  per line, smart quotes → ASCII, Unicode dashes → `-`, special spaces →
  space) and matches in that space — and, as in PI, if ANY edit needs the
  fuzzy pass the whole file is rewritten in normalized space. Every oldText
  must occur exactly once; all edits are matched against the same base
  content and spliced back-to-front.
  """
  use Catalyst.Tools.Tool
  alias Catalyst.Files.AtomicWrite
  alias Catalyst.Tools.{Diff, Paths}

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def name, do: "edit"

  @impl true
  def description,
    do:
      "Edit a file by replacing exact text. Provide `edits`: a list of " <>
        "{oldText, newText}. Each oldText must appear exactly once. Minor " <>
        "whitespace/Unicode-punctuation mismatches are tolerated (fuzzy match)."

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

    {updated, fuzzy?} = apply_edits(original, edits)
    AtomicWrite.write!(abs, updated)

    # The diff goes in the content too (not just details), so the model gets a
    # self-verification signal without re-reading the file. Scrub + cap it:
    # the file bytes may be invalid UTF-8 (JSON-encoding the transcript would
    # crash) and one huge line appears twice in a diff, blowing the budget.
    diff = Diff.rendered(original, updated)

    note =
      if fuzzy?,
        do: " (fuzzy match: whitespace/Unicode punctuation was normalized)",
        else: ""

    result(
      String.trim_trailing("Applied #{length(edits)} edit(s) to #{abs}#{note}\n\n" <> diff),
      %{
        path: abs,
        bytes_before: byte_size(original),
        bytes_after: byte_size(updated),
        fuzzy: fuzzy?,
        diff: diff
      }
    )
  end

  # Accept the canonical `edits` array, or a single oldText/newText pair.
  defp normalize_edits(%{"edits" => edits}) when is_list(edits) do
    Enum.map(edits, fn e -> {Map.fetch!(e, "oldText"), Map.fetch!(e, "newText")} end)
  end

  defp normalize_edits(%{"oldText" => old, "newText" => new}), do: [{old, new}]

  # Every oldText is located in the BASE content (unique + non-overlapping),
  # then all replacements are spliced positionally — so one edit's newText can
  # never change what another edit matches. PI parity: if any edit only
  # matches after fuzzy normalization, the base (and therefore the written
  # file) is the fuzzy-normalized content — acceptable, since fuzziness only
  # fixes minor formatting differences anyway.
  defp apply_edits(original, edits) do
    Enum.each(edits, fn {old, _new} ->
      if old == "", do: raise("edit failed: oldText must not be empty")
    end)

    normalized_original = normalize_fuzzy(original)
    normalized_edits = Enum.map(edits, fn {old, new} -> {normalize_fuzzy(old), new} end)

    fuzzy? =
      Enum.zip(edits, normalized_edits)
      |> Enum.any?(fn {{old, _new}, {normalized_old, _normalized_new}} ->
        not contains_exactly?(original, old) and
          contains_exactly?(normalized_original, normalized_old)
      end)

    {base, selected_edits} =
      case fuzzy? do
        true -> {normalized_original, normalized_edits}
        false -> {original, edits}
      end

    spans =
      selected_edits
      |> Enum.map(fn {old, new} ->
        {locate(base, old), old, new}
      end)
      |> Enum.sort_by(fn {start, _old, _new} -> start end)

    check_overlaps!(spans)

    # Walk forward once and materialize the final binary only at the boundary.
    {pieces, cursor} =
      Enum.reduce(spans, {[], 0}, fn {start, old, new}, {acc, cursor} ->
        unchanged = binary_part(base, cursor, start - cursor)
        {[new, unchanged | acc], start + byte_size(old)}
      end)

    tail = binary_part(base, cursor, byte_size(base) - cursor)
    updated = [tail | pieces] |> Enum.reverse() |> IO.iodata_to_binary()

    {updated, fuzzy?}
  end

  defp contains_exactly?(content, old), do: :binary.matches(content, old) != []

  # PI's normalizeForFuzzyMatch: NFKC, strip trailing whitespace per line,
  # smart quotes → ASCII, Unicode dashes/hyphens → "-", special spaces → " ".
  defp normalize_fuzzy(text) do
    text
    |> String.normalize(:nfkc)
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.replace(~r/[\x{2018}\x{2019}\x{201A}\x{201B}]/u, "'")
    |> String.replace(~r/[\x{201C}\x{201D}\x{201E}\x{201F}]/u, "\"")
    |> String.replace(~r/[\x{2010}\x{2011}\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}]/u, "-")
    |> String.replace(~r/[\x{00A0}\x{2002}-\x{200A}\x{202F}\x{205F}\x{3000}]/u, " ")
  end

  defp locate(content, old) do
    case :binary.matches(content, old) do
      [{start, _len}] ->
        start

      [] ->
        raise "edit failed: oldText not found (even with fuzzy matching): " <>
                inspect(String.slice(old, 0, 60))

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
