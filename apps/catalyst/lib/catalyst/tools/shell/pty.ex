defmodule Catalyst.Tools.Shell.Pty do
  @moduledoc """
  Pure command construction for PTY-backed shell sessions.

  BEAM `Port`s allocate no tty, so an interactive shell is wrapped in
  `script(1)`, which allocates a pseudo-terminal and bridges it to
  stdin/stdout. The wrapper invocation is platform-divergent — macOS
  (`script -q /dev/null <shell>`) and Linux (`script -qfc <shell> /dev/null`)
  take different argument shapes — so each divergence is exactly one clause
  here; only macOS is required to actually work (the capability gate never
  grants `:computer_use` elsewhere).

  Line-discipline consequences the caller must expect: the PTY **echoes
  written input back into the output stream**, and output newlines arrive as
  `\\r\\n`.
  """

  @doc """
  The `{executable, args}` pair that spawns `shell` under a PTY, or a tagged
  error when the platform has no known wrapper or `script(1)` is missing.

  ## Examples

      iex> Catalyst.Tools.Shell.Pty.wrap("/usr/bin/script", "/bin/sh", {:unix, :darwin})
      {:ok, {"/usr/bin/script", ["-q", "/dev/null", "/bin/sh"]}}

      iex> Catalyst.Tools.Shell.Pty.wrap("/usr/bin/script", "/bin/sh", {:unix, :linux})
      {:ok, {"/usr/bin/script", ["-qfc", "/bin/sh", "/dev/null"]}}

      iex> Catalyst.Tools.Shell.Pty.wrap("/usr/bin/script", "/bin/sh", {:win32, :nt})
      {:error, :unsupported_platform}

      iex> Catalyst.Tools.Shell.Pty.wrap(nil, "/bin/sh", {:unix, :darwin})
      {:error, :script_not_found}
  """
  @spec wrap(String.t() | nil, String.t(), {atom(), atom()}) ::
          {:ok, {String.t(), [String.t()]}} | {:error, :unsupported_platform | :script_not_found}
  def wrap(script_path, shell, os_type \\ :os.type())

  def wrap(nil, _shell, _os_type), do: {:error, :script_not_found}

  def wrap(script_path, shell, {:unix, :darwin}) when is_binary(script_path),
    do: {:ok, {script_path, ["-q", "/dev/null", shell]}}

  def wrap(script_path, shell, {:unix, _linux}) when is_binary(script_path),
    do: {:ok, {script_path, ["-qfc", shell, "/dev/null"]}}

  def wrap(_script_path, _shell, _os_type), do: {:error, :unsupported_platform}

  @doc """
  The shell to spawn when the caller names none: `$SHELL` when set and
  executable, then `/bin/zsh`, then `/bin/sh`.
  """
  @spec default_shell((String.t() -> String.t() | nil)) :: String.t()
  def default_shell(getenv \\ &System.get_env/1) do
    [getenv.("SHELL"), "/bin/zsh"]
    |> Enum.find("/bin/sh", &executable?/1)
  end

  defp executable?(nil), do: false

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      _missing_or_special -> false
    end
  end
end
