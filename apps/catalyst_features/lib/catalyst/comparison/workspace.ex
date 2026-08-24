defmodule Catalyst.Comparison.Workspace do
  @moduledoc """
  Captures dirty Git snapshots and provisions opaque independent clones.

  These functions perform blocking filesystem and process work and should run
  in supervised tasks rather than coordinator or LiveView callbacks.
  """

  alias Catalyst.Comparison.Store
  alias Catalyst.Files.AtomicWrite

  @snapshot_attempts 2

  @type snapshot :: map()
  @type workspace :: %{id: String.t(), cwd: Path.t()}

  @doc "Resolve the Git root containing `source`."
  @spec git_root(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def git_root(source) do
    source = Path.expand(source)

    with true <- File.dir?(source) or {:error, {:not_a_directory, source}},
         {:ok, root} <- git(["-C", source, "rev-parse", "--show-toplevel"]) do
      {:ok, String.trim(root)}
    end
  end

  @doc "Capture HEAD, tracked changes, and non-ignored untracked files."
  @spec capture_snapshot(Path.t(), String.t()) :: {:ok, snapshot()} | {:error, term()}
  def capture_snapshot(source_root, comparison_id) do
    snapshot_id = Catalyst.Ids.hex(12)

    case capture_snapshot(source_root, comparison_id, snapshot_id, @snapshot_attempts) do
      {:ok, _snapshot} = result ->
        result

      {:error, _reason} = error ->
        cleanup_snapshot(comparison_id, snapshot_id)
        error
    end
  end

  @doc "Provision an independent clone from a captured snapshot."
  @spec provision(Path.t(), String.t(), snapshot()) ::
          {:ok, workspace()} | {:error, term()}
  def provision(
        source_root,
        comparison_id,
        %{"id" => snapshot_id, "revision" => revision, "untracked_paths" => paths}
      ) do
    workspace_id = Catalyst.Ids.hex(16)
    workspace_root = Path.join(workspaces_root(), workspace_id)
    cwd = Path.join(workspace_root, "repo")

    with :ok <- File.mkdir_p(workspace_root),
         {:ok, _output} <-
           git(["clone", "--local", "--no-hardlinks", "--no-checkout", "--", source_root, cwd]),
         {:ok, _output} <- git(["-C", cwd, "checkout", "--detach", revision]),
         :ok <- apply_patch(cwd, comparison_id, snapshot_id),
         :ok <- copy_paths(snapshot_untracked(comparison_id, snapshot_id), cwd, paths),
         {:ok, _output} <- git(["-C", cwd, "remote", "remove", "origin"]) do
      {:ok, %{id: workspace_id, cwd: cwd}}
    else
      {:error, reason} ->
        File.rm_rf(workspace_root)
        {:error, {:lane_provision_failed, reason}}
    end
  end

  def provision(_source_root, _comparison_id, snapshot),
    do: {:error, {:invalid_comparison_snapshot, snapshot}}

  @doc "Remove the opaque workspace containing `cwd`."
  @spec cleanup(Path.t()) :: :ok
  def cleanup(cwd) do
    File.rm_rf(Path.dirname(cwd))
    :ok
  end

  @doc "Remove one captured snapshot."
  @spec cleanup_snapshot(String.t(), String.t()) :: :ok
  def cleanup_snapshot(comparison_id, snapshot_id) do
    File.rm_rf(snapshot_dir(comparison_id, snapshot_id))
    :ok
  end

  defp capture_snapshot(_source_root, _comparison_id, _snapshot_id, 0),
    do: {:error, :source_changed_during_snapshot}

  defp capture_snapshot(source_root, comparison_id, snapshot_id, attempts) do
    with {:ok, before} <- source_state(source_root),
         :ok <- write_snapshot(comparison_id, snapshot_id, source_root, before),
         {:ok, after_capture} <- source_state(source_root) do
      case before.signature == after_capture.signature do
        true ->
          {:ok,
           %{
             "id" => snapshot_id,
             "revision" => before.revision,
             "digest" => before.signature,
             "untracked_paths" => before.paths,
             "captured_at" => now()
           }}

        false ->
          capture_snapshot(source_root, comparison_id, snapshot_id, attempts - 1)
      end
    end
  end

  defp source_state(source_root) do
    with {:ok, revision} <- git(["-C", source_root, "rev-parse", "HEAD"]),
         {:ok, patch} <- git(["-C", source_root, "diff", "--binary", "HEAD", "--", "."]),
         {:ok, untracked} <-
           git(["-C", source_root, "ls-files", "--others", "--exclude-standard", "-z"]),
         paths = split_nul(untracked),
         {:ok, files_digest} <- digest_files(source_root, paths) do
      revision = String.trim(revision)
      signature = digest([revision, patch, Enum.join(paths, <<0>>), files_digest])
      {:ok, %{revision: revision, patch: patch, paths: paths, signature: signature}}
    end
  end

  defp write_snapshot(comparison_id, snapshot_id, source_root, state) do
    directory = snapshot_dir(comparison_id, snapshot_id)
    File.rm_rf(directory)

    with :ok <- File.mkdir_p(directory),
         :ok <- AtomicWrite.write(Path.join(directory, "tracked.patch"), state.patch),
         :ok <-
           copy_paths(source_root, snapshot_untracked(comparison_id, snapshot_id), state.paths) do
      :ok
    end
  end

  defp apply_patch(cwd, comparison_id, snapshot_id) do
    path = Path.join(snapshot_dir(comparison_id, snapshot_id), "tracked.patch")

    case File.stat(path) do
      {:ok, %File.Stat{size: 0}} -> :ok
      {:ok, _stat} -> git_ok(["-C", cwd, "apply", "--binary", "--", path])
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_paths(source_root, destination_root, paths) do
    Enum.reduce_while(paths, :ok, fn relative, :ok ->
      source = Path.join(source_root, relative)
      destination = Path.join(destination_root, relative)

      result =
        with :ok <- File.mkdir_p(Path.dirname(destination)),
             {:ok, stat} <- File.lstat(source) do
          copy_path(source, destination, stat.type)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:copy_failed, relative, reason}}}
      end
    end)
  end

  defp copy_path(source, destination, :regular), do: File.cp(source, destination)

  defp copy_path(source, destination, :symlink) do
    with {:ok, target} <- File.read_link(source) do
      File.ln_s(target, destination)
    end
  end

  defp copy_path(_source, _destination, type), do: {:error, {:unsupported_file_type, type}}

  defp digest_files(root, paths) do
    Enum.reduce_while(paths, {:ok, :crypto.hash_init(:sha256)}, fn relative, {:ok, context} ->
      path = Path.join(root, relative)

      case digest_path(path, context) do
        {:ok, context} ->
          context = :crypto.hash_update(context, [relative, <<0>>])
          {:cont, {:ok, context}}

        {:error, reason} ->
          {:halt, {:error, {:digest_failed, relative, reason}}}
      end
    end)
    |> case do
      {:ok, context} -> {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      error -> error
    end
  end

  defp digest_path(path, context) do
    with {:ok, stat} <- File.lstat(path) do
      case stat.type do
        :regular ->
          context =
            path
            |> File.stream!(64 * 1024, [])
            |> Enum.reduce(context, &:crypto.hash_update(&2, &1))

          {:ok, context}

        :symlink ->
          with {:ok, target} <- File.read_link(path) do
            {:ok, :crypto.hash_update(context, target)}
          end

        type ->
          {:error, {:unsupported_file_type, type}}
      end
    end
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, status, String.trim(output)}}
    end
  rescue
    exception -> {:error, {:git_failed, exception}}
  end

  defp git_ok(args) do
    case git(args) do
      {:ok, _output} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp snapshot_dir(comparison_id, snapshot_id),
    do: Path.join([Store.dir(comparison_id), "snapshots", snapshot_id])

  defp snapshot_untracked(comparison_id, snapshot_id),
    do: Path.join(snapshot_dir(comparison_id, snapshot_id), "untracked")

  defp workspaces_root,
    do: Application.get_env(:catalyst, :workspaces_root) || Catalyst.Paths.join("workspaces")

  defp split_nul(""), do: []
  defp split_nul(value), do: value |> String.split(<<0>>, trim: true) |> Enum.sort()
  defp digest(iodata), do: :sha256 |> :crypto.hash(iodata) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
