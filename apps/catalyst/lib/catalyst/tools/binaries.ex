defmodule Catalyst.Tools.Binaries do
  @moduledoc """
  Resolves the fast-tool binaries (`rg`, `fd`, `sd`, `ast-grep`) once and caches
  the path. Resolution order: `~/.catalyst/bin`, then `$PATH`.

  This is the single seam for PI's `ensureTool` auto-download behaviour. P1
  resolves already-installed binaries; `download/1` (the on-demand fetch into
  `~/.catalyst/bin`) is wired for P4 packaging — until then a missing binary
  raises with an install hint.
  """

  @tools %{
    rg: %{exe: "rg", brew: "ripgrep", repo: "BurntSushi/ripgrep"},
    fd: %{exe: "fd", brew: "fd", repo: "sharkdp/fd"},
    sd: %{exe: "sd", brew: "sd", repo: "chmln/sd"},
    ast_grep: %{exe: "ast-grep", brew: "ast-grep", repo: "ast-grep/ast-grep"}
  }

  @doc "Known tool keys."
  def tools, do: Map.keys(@tools)

  @doc """
  Absolute path to a tool binary, or `{:error, {:missing, tool, hint}}`.
  Cached in `:persistent_term` after the first successful resolution.
  """
  @spec path(atom()) :: {:ok, String.t()} | {:error, term()}
  def path(tool) when is_map_key(@tools, tool) do
    case :persistent_term.get({__MODULE__, tool}, nil) do
      nil -> resolve_and_cache(tool)
      cached -> {:ok, cached}
    end
  end

  def path(tool), do: {:error, {:unknown_tool, tool}}

  @doc "Like `path/1` but raises a helpful error if the binary cannot be found."
  @spec path!(atom()) :: String.t()
  def path!(tool) do
    case path(tool) do
      {:ok, p} -> p
      {:error, {:missing, _tool, hint}} -> raise hint
      {:error, reason} -> raise "could not resolve #{inspect(tool)}: #{inspect(reason)}"
    end
  end

  defp resolve_and_cache(tool) do
    spec = @tools[tool]

    case discover(spec.exe) do
      nil ->
        # P4: attempt download(tool) here before failing.
        {:error, {:missing, tool, install_hint(tool, spec)}}

      found ->
        :persistent_term.put({__MODULE__, tool}, found)
        {:ok, found}
    end
  end

  defp discover(exe) do
    local = Path.join(bin_dir(), exe)

    cond do
      File.exists?(local) -> local
      true -> System.find_executable(exe)
    end
  end

  @doc "Directory for on-demand downloaded binaries."
  def bin_dir, do: Path.expand("~/.catalyst/bin")

  defp install_hint(tool, spec) do
    "fast-tool #{inspect(tool)} (#{spec.exe}) not found on PATH or in #{bin_dir()}. " <>
      "Install it (e.g. `brew install #{spec.brew}`) or wait for auto-download (P4). " <>
      "Releases: https://github.com/#{spec.repo}/releases"
  end

  @doc false
  # P4: download the correct release asset for the host OS/arch into bin_dir().
  def download(tool), do: {:error, {:not_implemented, tool}}
end
