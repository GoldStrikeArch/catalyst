defmodule Catalyst.Tools.Edit do
  @moduledoc """
  Targeted string-replacement edits (PI's `edit`). Each `oldText` must occur
  exactly once in the original file; all edits are matched against the original
  and applied in order. (Fuzzy/Unicode-normalized matching is a later refinement;
  for structural edits use the `ast_grep` tool.)
  """
  use Catalyst.Tools.Tool
  alias Catalyst.Tools.Paths

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
        "path" => %{"type" => "string", "description" => "File path (relative to cwd or absolute)"},
        "edits" => %{
          "type" => "array",
          "description" => "List of replacements applied against the original file",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "oldText" => %{"type" => "string", "description" => "Exact text to find (must be unique)"},
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

    updated = Enum.reduce(edits, original, fn {old, new}, acc -> apply_edit(acc, old, new) end)
    File.write!(abs, updated)

    result("Applied #{length(edits)} edit(s) to #{abs}", %{
      path: abs,
      bytes_before: byte_size(original),
      bytes_after: byte_size(updated)
    })
  end

  # Accept the canonical `edits` array, or a single oldText/newText pair.
  defp normalize_edits(%{"edits" => edits}) when is_list(edits) do
    Enum.map(edits, fn e -> {Map.fetch!(e, "oldText"), Map.fetch!(e, "newText")} end)
  end

  defp normalize_edits(%{"oldText" => old, "newText" => new}), do: [{old, new}]

  defp apply_edit(_content, "", _new), do: raise("edit failed: oldText must not be empty")

  defp apply_edit(content, old, new) do
    case count_occurrences(content, old) do
      0 -> raise "edit failed: oldText not found: #{inspect(String.slice(old, 0, 60))}"
      1 -> String.replace(content, old, new)
      n -> raise "edit failed: oldText occurs #{n} times (must be unique): #{inspect(String.slice(old, 0, 60))}"
    end
  end

  defp count_occurrences(content, old), do: length(String.split(content, old)) - 1
end
