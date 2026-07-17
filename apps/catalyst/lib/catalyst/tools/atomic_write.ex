defmodule Catalyst.Tools.AtomicWrite do
  @moduledoc """
  Crash-safe file replacement for the edit/write tools.

  A plain `File.write!/2` opens with O_TRUNC: ENOSPC, a BEAM crash, or power
  loss between the truncate and the final write leaves the file empty or
  partial with the original content unrecoverable. Writing to a temp file in
  the target's directory, fsyncing, and renaming over the target is atomic on
  POSIX filesystems — readers see either the old content or the new, never a
  torn file.
  """

  import Bitwise, only: [band: 2]

  # Bounded symlink resolution; deeper chains than this are pathological.
  @max_symlink_hops 8

  @doc """
  Atomically replace `path` with `content`.

  Preserves an existing file's permission bits and writes through symlinks
  (replacing the link target, not the link). Raises on failure, like
  `File.write!/2`; the temp file is removed on any error.
  """
  @spec write!(Path.t(), iodata()) :: :ok
  def write!(path, content) do
    target = resolve_symlinks(path, @max_symlink_hops)
    tmp = tmp_path(target)

    try do
      write_synced!(tmp, content)
      preserve_mode(target, tmp)
      File.rename!(tmp, target)
    after
      # Gone already on success; best-effort cleanup on failure.
      File.rm(tmp)
    end

    :ok
  end

  # Renaming over a symlink would replace the link itself, silently turning
  # e.g. a symlinked dotfile into a regular file — follow it instead.
  defp resolve_symlinks(path, 0), do: path

  defp resolve_symlinks(path, hops) do
    case :file.read_link(path) do
      {:ok, target} ->
        target
        |> List.to_string()
        |> Path.expand(Path.dirname(path))
        |> resolve_symlinks(hops - 1)

      _not_a_link ->
        path
    end
  end

  defp tmp_path(target) do
    Path.join(
      Path.dirname(target),
      ".#{Path.basename(target)}.catalyst-#{System.unique_integer([:positive])}.tmp"
    )
  end

  defp write_synced!(tmp, content) do
    fd = File.open!(tmp, [:write, :binary, :raw])

    try do
      with :ok <- :file.write(fd, content),
           :ok <- :file.sync(fd) do
        :ok
      else
        {:error, reason} -> raise File.Error, reason: reason, action: "write", path: tmp
      end
    after
      :file.close(fd)
    end
  end

  defp preserve_mode(target, tmp) do
    case File.stat(target) do
      # stat's mode carries file-type bits too; chmod takes only permissions.
      {:ok, %File.Stat{mode: mode}} -> File.chmod!(tmp, band(mode, 0o7777))
      {:error, _no_existing_file} -> :ok
    end
  end
end
