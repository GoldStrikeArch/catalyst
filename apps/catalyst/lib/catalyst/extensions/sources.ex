defmodule Catalyst.Extensions.Sources do
  @moduledoc """
  Pure source-path conventions for runtime extensions.

  Filesystem mutation and load orchestration stay in `Catalyst.Extensions.Load`;
  this module owns only discovery, owner normalization, and managed-path checks.

  Immutable extensions bundled by Catalyst live under each loaded Catalyst
  application's `priv/builtins/` directory. User extensions live in `dir/0`.
  Both use the same owner convention, so a user file with the same basename
  replaces its bundled counterpart when sources are loaded in precedence order.
  """

  @bundled_apps [:catalyst, :catalyst_web, :catalyst_desktop, :catalyst_cli]

  @doc "Return the configured runtime extension directory."
  @spec dir() :: Path.t()
  def dir, do: Application.get_env(:catalyst, :extensions_dir) || Catalyst.Paths.extensions()

  @doc "Normalize a source name into its stable extension owner id."
  @spec sanitize_owner(String.t()) :: String.t()
  def sanitize_owner(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
  end

  @doc "List enabled extension source files in stable path order."
  @spec enabled_files() :: [Path.t()]
  def enabled_files, do: wildcard(dir(), "*.ex")

  @doc """
  List immutable bundled extension sources in stable application and path order.

  `:bundled_extensions_dirs` may be configured explicitly, primarily for
  embedding Catalyst or testing source precedence.
  """
  @spec bundled_files() :: [Path.t()]
  def bundled_files do
    :catalyst
    |> Application.get_env(:bundled_extensions_dirs, default_bundled_dirs())
    |> Enum.flat_map(&wildcard(&1, "*.ex"))
  end

  @doc "List disabled extension source files in stable path order."
  @spec disabled_files() :: [Path.t()]
  def disabled_files, do: wildcard(dir(), "*.ex.disabled")

  @doc "Return the normalized owner id for an enabled source path."
  @spec owner(Path.t()) :: String.t()
  def owner(path), do: path |> Path.basename(".ex") |> sanitize_owner()

  @doc "Return the normalized owner id for a disabled source path."
  @spec disabled_owner(Path.t()) :: String.t()
  def disabled_owner(path), do: path |> Path.basename(".ex.disabled") |> sanitize_owner()

  @doc "Group unique expanded source paths by normalized owner."
  @spec index_by_owner([Path.t()]) :: %{optional(String.t()) => [Path.t()]}
  def index_by_owner(paths) do
    paths
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.group_by(&owner/1)
  end

  @doc "Find the source path whose derived owner equals `owner`."
  @spec find([Path.t()], String.t(), (Path.t() -> String.t())) :: {:ok, Path.t()} | :error
  def find(paths, owner, owner_fun) do
    case Enum.find(paths, &(owner_fun.(&1) == owner)) do
      nil -> :error
      path -> {:ok, path}
    end
  end

  @doc "Return whether `path` is contained by the managed extension directory."
  @spec managed?(Path.t() | nil) :: boolean()
  def managed?(nil), do: false

  def managed?(path) do
    relative = path |> Path.expand() |> Path.relative_to(Path.expand(dir()))

    Path.type(relative) == :relative and relative != ".." and
      not String.starts_with?(relative, "../")
  end

  @doc "Validate that a source path is managed by the extension directory."
  @spec ensure_managed(Path.t()) :: :ok | {:error, :external_source}
  def ensure_managed(path) do
    case managed?(path) do
      true -> :ok
      false -> {:error, :external_source}
    end
  end

  defp wildcard(directory, pattern) do
    case File.dir?(directory) do
      true -> directory |> Path.join(pattern) |> Path.wildcard()
      false -> []
    end
  end

  defp default_bundled_dirs do
    @bundled_apps
    |> Enum.filter(&(not is_nil(Application.spec(&1, :vsn))))
    |> Enum.map(&Application.app_dir(&1, "priv/builtins"))
  end
end
