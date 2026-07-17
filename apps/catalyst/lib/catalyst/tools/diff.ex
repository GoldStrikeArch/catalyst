defmodule Catalyst.Tools.Diff do
  @moduledoc """
  Minimal unified diff between two strings (`List.myers_difference/2` on lines).

  Used by the `edit`/`replace` tools so their results carry a self-verification
  signal — the agent sees exactly what changed without re-reading the file.
  """

  @context 3
  @default_max_lines 200

  @doc """
  Unified diff of `old` → `new` (`""` when equal). `opts`: `:max_lines` caps the
  output (default #{@default_max_lines}) with a truncation note.
  """
  def unified(old, new, opts \\ [])

  def unified(same, same, _opts), do: ""

  def unified(old, new, opts) do
    String.split(old, "\n")
    |> List.myers_difference(String.split(new, "\n"))
    |> Enum.flat_map(fn {tag, lines} -> Enum.map(lines, &{tag, &1}) end)
    |> annotate()
    |> hunks()
    |> Enum.map_join("\n", &format_hunk/1)
    |> cap(Keyword.get(opts, :max_lines, @default_max_lines))
  end

  # Attach 1-based old/new line numbers to each op.
  defp annotate(ops) do
    {annotated, _counters} =
      Enum.map_reduce(ops, {1, 1}, fn
        {:eq, line}, {o, n} -> {{:eq, line, o, n}, {o + 1, n + 1}}
        {:del, line}, {o, n} -> {{:del, line, o, n}, {o + 1, n}}
        {:ins, line}, {o, n} -> {{:ins, line, o, n}, {o, n + 1}}
      end)

    annotated
  end

  # Cluster changed lines (gaps ≤ 2×context merge), pad each cluster with context.
  defp hunks(annotated) do
    annotated
    |> Enum.with_index()
    |> Enum.reject(fn {{tag, _, _, _}, _i} -> tag == :eq end)
    |> Enum.map(fn {_op, i} -> i end)
    |> Enum.chunk_while(
      [],
      fn i, acc ->
        case acc do
          [] -> {:cont, [i]}
          [prev | _] when i - prev <= @context * 2 -> {:cont, [i | acc]}
          _ -> {:cont, Enum.reverse(acc), [i]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.map(fn cluster ->
      first = max(List.first(cluster) - @context, 0)
      last = min(List.last(cluster) + @context, length(annotated) - 1)
      Enum.slice(annotated, first..last)
    end)
  end

  defp format_hunk([{_tag, _line, o, n} | _] = ops) do
    old_count = Enum.count(ops, fn {tag, _, _, _} -> tag in [:eq, :del] end)
    new_count = Enum.count(ops, fn {tag, _, _, _} -> tag in [:eq, :ins] end)

    body =
      Enum.map_join(ops, "\n", fn
        {:eq, line, _, _} -> " " <> line
        {:del, line, _, _} -> "-" <> line
        {:ins, line, _, _} -> "+" <> line
      end)

    "@@ -#{o},#{old_count} +#{n},#{new_count} @@\n" <> body
  end

  defp cap(diff, max) do
    lines = String.split(diff, "\n")

    if length(lines) > max do
      (lines |> Enum.take(max) |> Enum.join("\n")) <> "\n… (diff truncated)"
    else
      diff
    end
  end
end
