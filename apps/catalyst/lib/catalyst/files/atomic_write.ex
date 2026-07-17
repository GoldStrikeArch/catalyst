defmodule Catalyst.Files.AtomicWrite do
  @moduledoc """
  Atomic file replacement shared by tools and application persistence.

  Content is written to a uniquely named temporary file in the target's
  directory, synchronized, and renamed over the target. Readers therefore see
  either the old file or the complete replacement across process/VM crashes.
  The containing directory is not synchronized, so this module does not claim
  that the rename itself survives sudden power loss.

  Existing permission bits are preserved by default. Pass `mode: 0o600` (or
  another permission mode) to override them. The temporary file is chmodded
  before content is written, so sensitive bytes are never present with wider
  temporary permissions.
  """

  import Bitwise, only: [band: 2]

  @max_symlink_hops 8

  @typedoc "Options accepted by `write/3` and `write!/3`."
  @type option :: {:mode, 0..0o7777}

  @doc """
  Atomically replace `path` with `content` without raising.

  Writes through symlinks (replacing their target rather than the link),
  preserves an existing file's mode unless `:mode` is provided, and removes
  the temporary file after both success and failure.
  """
  @spec write(Path.t(), iodata(), [option()]) :: :ok | {:error, term()}
  def write(path, content, opts \\ []) do
    target = resolve_symlinks(path, @max_symlink_hops)
    temp = temp_path(target)

    try do
      with {:ok, mode} <- desired_mode(target, opts),
           :ok <- write_temp(temp, content, mode),
           :ok <- File.rename(temp, target) do
        :ok
      end
    after
      File.rm(temp)
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Atomically replace `path` with `content`, raising on failure.

  This is the raising counterpart to `write/3` and retains the contract used
  by the edit/write tools and extension installer.
  """
  @spec write!(Path.t(), iodata(), [option()]) :: :ok
  def write!(path, content, opts \\ []) do
    case write(path, content, opts) do
      :ok -> :ok
      {:error, %{__exception__: true} = exception} -> raise exception
      {:error, reason} -> raise File.Error, reason: reason, action: "write", path: path
    end
  end

  # Renaming over a symlink would replace the link itself, silently turning a
  # symlinked dotfile into a regular file. Follow it instead.
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

  defp temp_path(target) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    Path.join(Path.dirname(target), ".#{Path.basename(target)}.catalyst-#{suffix}.tmp")
  end

  defp desired_mode(target, opts) do
    case Keyword.fetch(opts, :mode) do
      {:ok, mode} when is_integer(mode) and mode in 0..0o7777 -> {:ok, mode}
      {:ok, mode} -> {:error, {:invalid_mode, mode}}
      :error -> existing_mode(target)
    end
  end

  defp existing_mode(target) do
    case File.stat(target) do
      {:ok, %File.Stat{mode: mode}} -> {:ok, band(mode, 0o7777)}
      {:error, _no_existing_file} -> {:ok, nil}
    end
  end

  defp write_temp(temp, content, mode) do
    case File.open(temp, [:write, :binary, :raw, :exclusive]) do
      {:ok, file} -> write_open_temp(file, temp, content, mode)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_open_temp(file, temp, content, mode) do
    try do
      with :ok <- set_mode(temp, mode),
           :ok <- :file.write(file, content),
           :ok <- :file.sync(file) do
        :ok
      end
    after
      :file.close(file)
    end
  end

  defp set_mode(_temp, nil), do: :ok
  defp set_mode(temp, mode), do: File.chmod(temp, mode)
end
