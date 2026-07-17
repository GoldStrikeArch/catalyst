defmodule CatalystWeb.FileSearch do
  @moduledoc """
  Filename search behind the chat input's `@` references, backed by `fd`.

  `search/2` returns up to #{8} candidates as `%{path, label}`: `path` is
  relative to the session cwd (what the prompt receives after expansion), and
  `label` is the short display/insert form `@<parent>/<name>` — extended upward
  one directory at a time only as far as needed to tell same-named files apart
  (`@session/server.ex` vs `@qwe/server.ex`).

  Degrades to `[]` on any failure (no fd binary, bad pattern, timeout): the
  dropdown simply shows nothing.
  """

  alias Catalyst.Tools.{Binaries, Exec}

  @limit 8
  @timeout 3_000

  @type result :: %{path: String.t(), label: String.t()}

  @doc "Search file names under `cwd` for `query` (empty query lists the first few files)."
  @spec search(Path.t(), String.t()) :: [result()]
  def search(cwd, query) do
    with {:ok, fd} <- Binaries.path(:fd),
         {:ok, %{out: out, status: 0}} <-
           Exec.collect(fd, fd_args(query), cwd: cwd, timeout: @timeout) do
      out
      |> String.split("\n", trim: true)
      |> Enum.take(@limit)
      |> disambiguate()
    else
      _error -> []
    end
  rescue
    _e -> []
  end

  # `--full-path` so "session/serv" style queries (the same shape as the labels
  # we insert) match too, not just bare file names.
  defp fd_args(""), do: ["--type", "f", "--max-results", "#{@limit}"]

  defp fd_args(query),
    do: ["--type", "f", "--full-path", "--max-results", "#{@limit}", "--", query]

  # ---- labels -------------------------------------------------------------------

  # Start every label at <parent>/<name>; groups that still collide get one
  # more leading segment until unique (or the full path is used). Unique files
  # keep the short two-segment form even when other results needed more.
  defp disambiguate(paths) do
    paths
    |> Enum.with_index()
    |> Enum.map(fn {path, i} -> %{i: i, path: path, segs: Path.split(path)} end)
    |> resolve_labels(2)
    |> Enum.sort_by(& &1.i)
    |> Enum.map(&%{path: &1.path, label: &1.label})
  end

  defp resolve_labels(entries, depth) do
    entries
    |> Enum.group_by(fn entry -> label_for(entry.segs, depth) end)
    |> Enum.flat_map(fn
      {label, [entry]} ->
        [Map.put(entry, :label, label)]

      {label, group} ->
        case Enum.all?(group, fn entry -> length(entry.segs) <= depth end) do
          # Identical full paths (shouldn't happen) — nothing left to extend.
          true -> Enum.map(group, &Map.put(&1, :label, label))
          false -> resolve_labels(group, depth + 1)
        end
    end)
  end

  defp label_for(segs, depth) do
    "@" <> (segs |> Enum.take(-min(depth, length(segs))) |> Path.join())
  end
end
