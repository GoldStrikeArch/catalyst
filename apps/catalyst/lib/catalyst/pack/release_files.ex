defmodule Catalyst.Pack.ReleaseFiles do
  @moduledoc """
  Host-neutral executable inputs selected from a product's pack release plan.

  Release packaging resolves the same product and host pair used at runtime:
  the desktop release uses the default desktop product, while the CLI release
  uses the minimal CLI product. Copying happens only after an assembled release
  exposes the core application's `priv` directory.
  """

  alias Catalyst.Pack.ReleasePlan

  @type executable :: %{
          kind: :executable,
          id: String.t(),
          source: String.t(),
          target: String.t(),
          pack_id: String.t()
        }
  @type resolver :: (String.t() -> Path.t() | nil)

  @doc "Return the pack plan pinned to a shipped release target."
  @spec plan(atom(), :darwin | :linux | :windows) ::
          {:ok, ReleasePlan.t()} | {:error, term()}
  def plan(release_name, platform) do
    with {:ok, product, host} <- release_target(release_name) do
      ReleasePlan.for_target(product.spec(), host, platform)
    end
  end

  @doc "Return executable contributions for a shipped release target."
  @spec executables(atom(), :darwin | :linux | :windows) ::
          {:ok, [executable()]} | {:error, term()}
  def executables(release_name, platform) do
    with {:ok, plan} <- plan(release_name, platform) do
      executables =
        for %{pack_id: pack_id, declaration: %{kind: :executable} = declaration} <-
              plan.contributions,
            do: Map.put(declaration, :pack_id, pack_id)

      {:ok, executables}
    end
  end

  @doc "Return preflight checks for executable contributions."
  @spec checks([executable()], resolver()) :: [{Path.t() | nil, String.t()}]
  def checks(executables, resolver \\ &System.find_executable/1)
      when is_list(executables) and is_function(resolver, 1) do
    Enum.map(executables, fn executable ->
      {resolver.(executable.source),
       "executable `#{executable.source}` from pack #{executable.pack_id} on PATH"}
    end)
  end

  @doc "Copy executable contributions beneath an assembled core application directory."
  @spec copy([executable()], Path.t(), resolver()) :: :ok | {:error, term()}
  def copy(executables, app_dir, resolver \\ &System.find_executable/1)
      when is_list(executables) and is_binary(app_dir) and is_function(resolver, 1) do
    Enum.reduce_while(executables, :ok, fn executable, :ok ->
      case copy_executable(executable, app_dir, resolver) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "Return the current release build platform."
  @spec platform() :: :darwin | :linux | :windows
  def platform do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:win32, _name} -> :windows
      _other -> :linux
    end
  end

  defp release_target(:catalyst_desktop),
    do: {:ok, Catalyst.Product.Default, :desktop}

  defp release_target(:catalyst_cli),
    do: {:ok, Catalyst.Product.MinimalCLI, :cli}

  defp release_target(name), do: {:error, {:unknown_catalyst_release, name}}

  defp copy_executable(executable, app_dir, resolver) do
    with source when is_binary(source) <- resolver.(executable.source),
         destination = Path.join(app_dir, executable.target),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.cp(source, destination),
         :ok <- File.chmod(destination, 0o755) do
      :ok
    else
      nil -> {:error, {:release_executable_missing, executable.pack_id, executable.source}}
      {:error, reason} -> {:error, {:release_executable_copy_failed, executable.id, reason}}
    end
  end
end
