defmodule CatalystWeb.Workbench.Workspace do
  @moduledoc "Workspace-confined file access and bounded command execution for the IDE host."

  alias Catalyst.Files.AtomicWrite
  alias Catalyst.Tools.Exec

  @max_file_bytes 1_048_576
  @max_entries 1_000
  @max_depth 6
  @ignored_directories MapSet.new(~w(.git .elixir_ls _build deps node_modules))

  @doc "Validate a regular, non-symlink workspace directory."
  @spec root(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def root(path) when is_binary(path) do
    expanded = Path.expand(path)

    case File.lstat(expanded) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, expanded}
      {:ok, _unsafe} -> {:error, :unsafe_workspace}
      {:error, reason} -> {:error, {:workspace_unavailable, reason}}
    end
  end

  def root(path), do: {:error, {:invalid_workspace, path}}

  @doc "List a bounded set of regular files without following symlinks."
  @spec list_files(Path.t()) :: {:ok, [Path.t()]} | {:error, term()}
  def list_files(root) do
    with {:ok, root} <- root(root) do
      files = collect([{root, [], 0}], [], 0)
      {:ok, Enum.sort(files)}
    end
  end

  @doc "Read one UTF-8 regular file confined to the workspace."
  @spec read_file(Path.t(), Path.t()) ::
          {:ok, %{path: Path.t(), content: String.t()}} | {:error, term()}
  def read_file(root, relative) do
    with {:ok, file} <- regular_file(root, relative),
         {:ok, stat} <- File.stat(file),
         :ok <- bounded_size(stat.size),
         {:ok, content} <- File.read(file),
         true <- String.valid?(content) do
      {:ok, %{path: relative, content: content}}
    else
      false -> {:error, :non_utf8_file}
      {:error, _reason} = error -> error
    end
  end

  @doc "Atomically replace one existing regular UTF-8 file inside the workspace."
  @spec write_file(Path.t(), Path.t(), String.t()) :: :ok | {:error, term()}
  def write_file(root, relative, content) when is_binary(content) do
    with :ok <- bounded_size(byte_size(content)),
         true <- String.valid?(content),
         {:ok, file} <- regular_file(root, relative) do
      AtomicWrite.write(file, content)
    else
      false -> {:error, :non_utf8_file}
      {:error, _reason} = error -> error
    end
  end

  def write_file(_root, _relative, content), do: {:error, {:invalid_file_content, content}}

  @doc "Run one bounded shell command with the workspace as its working directory."
  @spec run_command(Path.t(), String.t()) :: Exec.collect_result() | {:error, term()}
  def run_command(root, command) when is_binary(command) do
    with {:ok, root} <- root(root) do
      Exec.bash(command, cwd: root, timeout: 60_000, max_output_bytes: 262_144)
    end
  end

  def run_command(_root, command), do: {:error, {:invalid_command, command}}

  defp collect(_queue, files, seen) when seen >= @max_entries, do: files
  defp collect([], files, _seen), do: files

  defp collect([{directory, relative, depth} | queue], files, seen) do
    case File.ls(directory) do
      {:ok, entries} -> collect_entries(entries, directory, relative, depth, queue, files, seen)
      {:error, _reason} -> collect(queue, files, seen + 1)
    end
  end

  defp collect_entries(entries, directory, relative, depth, queue, files, seen) do
    {queue, files, seen} =
      entries
      |> Enum.sort()
      |> Enum.reduce_while({queue, files, seen}, fn entry, {dirs, paths, count} ->
        case count >= @max_entries do
          true -> {:halt, {dirs, paths, count}}
          false -> {:cont, collect_entry(directory, relative, depth, entry, dirs, paths, count)}
        end
      end)

    collect(queue, files, seen)
  end

  defp collect_entry(directory, relative, depth, entry, queue, files, seen) do
    path = Path.join(directory, entry)
    segments = [entry | relative]

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        {queue, [segments |> Enum.reverse() |> Enum.join("/") | files], seen + 1}

      {:ok, %File.Stat{type: :directory}} when depth < @max_depth ->
        case MapSet.member?(@ignored_directories, entry) do
          true -> {queue, files, seen + 1}
          false -> {[{path, segments, depth + 1} | queue], files, seen + 1}
        end

      _unsafe_or_unavailable ->
        {queue, files, seen + 1}
    end
  end

  defp regular_file(root, relative) do
    with {:ok, root} <- root(root),
         {:ok, segments} <- relative_segments(relative) do
      walk(root, segments)
    end
  end

  defp relative_segments(relative) when is_binary(relative) do
    segments = String.split(relative, "/", trim: false)

    case segments != [] and
           Enum.all?(segments, &valid_segment?/1) do
      true -> {:ok, segments}
      false -> {:error, :unsafe_workspace_path}
    end
  end

  defp relative_segments(_relative), do: {:error, :unsafe_workspace_path}

  defp valid_segment?(segment) do
    segment not in ["", ".", ".."] and not String.contains?(segment, ["\\", <<0>>])
  end

  defp walk(parent, [file]) do
    path = Path.join(parent, file)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, path}
      _unsafe_or_missing -> {:error, :unsafe_workspace_path}
    end
  end

  defp walk(parent, [directory | rest]) do
    path = Path.join(parent, directory)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk(path, rest)
      _unsafe_or_missing -> {:error, :unsafe_workspace_path}
    end
  end

  defp bounded_size(size) when size <= @max_file_bytes, do: :ok
  defp bounded_size(_size), do: {:error, :file_too_large}
end
