defmodule Catalyst.Tools.Binaries do
  @moduledoc """
  Resolves the fast-tool binaries (`rg`, `fd`, `sd`, `ast-grep`) and the native
  computer-use helper (`catalyst-input`) once and caches the path. Resolution
  order: `~/.catalyst/bin`, then the bundled `priv/bin` (shipped in the
  release/.app), then `$PATH`, then the common Homebrew locations (a GUI .app
  inherits a minimal PATH). A missing binary raises with an install hint —
  `brew install` for the fast tools, `mix catalyst.computer.build` for the
  built-not-brewed helper.
  """

  alias Catalyst.Paths

  @tools %{
    rg: %{exe: "rg", brew: "ripgrep", repo: "BurntSushi/ripgrep"},
    fd: %{exe: "fd", brew: "fd", repo: "sharkdp/fd"},
    sd: %{exe: "sd", brew: "sd", repo: "chmln/sd"},
    ast_grep: %{exe: "ast-grep", brew: "ast-grep", repo: "ast-grep/ast-grep"},
    # Built from rel/macos/computer_helper.m, not brewed — hence the custom
    # install hint. The release bundles it into priv/bin.
    catalyst_input: %{
      exe: "catalyst-input",
      hint:
        "the native computer-use helper (catalyst-input) was not found. " <>
          "Build it with `mix catalyst.computer.build` (macOS, requires the " <>
          "Xcode command line tools); releases bundle it automatically."
    }
  }

  @doc "Known tool keys."
  @spec tools() :: [atom()]
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

  @doc """
  Resolve a tool through the documented search order without reading or
  writing the `:persistent_term` cache. Callers that must observe an install
  or removal on every check (`Catalyst.Tools.Computer.Availability`) use this
  instead of `path/1`; a stale cached path could otherwise report a deleted
  helper as ready. Returns the same tagged tuples as `path/1`.
  """
  @spec discover(atom()) :: {:ok, String.t()} | {:error, term()}
  def discover(tool) when is_map_key(@tools, tool) do
    spec = @tools[tool]

    case search(spec.exe) do
      nil -> {:error, {:missing, tool, install_hint(tool, spec)}}
      found -> {:ok, found}
    end
  end

  def discover(tool), do: {:error, {:unknown_tool, tool}}

  defp resolve_and_cache(tool) do
    case discover(tool) do
      {:ok, found} ->
        :persistent_term.put({__MODULE__, tool}, found)
        {:ok, found}

      {:error, _reason} = error ->
        error
    end
  end

  # Resolution order: ~/.catalyst/bin, the bundled priv/bin (shipped in the .app),
  # $PATH, then common Homebrew locations (a GUI .app inherits a minimal PATH that
  # usually excludes /opt/homebrew/bin and /usr/local/bin). An empty dir (no priv
  # dir) is skipped — Path.join("", exe) would "find" a same-named file in the
  # BEAM's cwd — and candidates must actually be executable, not just present.
  defp search(exe) do
    bundled =
      [bin_dir(), bundled_dir()]
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Path.join(&1, exe))
      |> Enum.find(&executable?/1)

    bundled || System.find_executable(exe) ||
      ["/opt/homebrew/bin", "/usr/local/bin"]
      |> Enum.map(&Path.join(&1, exe))
      |> Enum.find(&executable?/1)
  end

  @doc """
  Whether `path` is an executable regular file (any execute bit set) — the
  usability bar every discovered candidate must clear. One `File.stat/2`
  call; a missing or non-regular file is simply `false`.
  """
  @spec executable?(Path.t()) :: boolean()
  def executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _missing_or_not_regular -> false
    end
  end

  @doc "Directory for user-installed tool binaries (`~/.catalyst/bin`)."
  @spec bin_dir() :: String.t()
  def bin_dir, do: Paths.join("bin")

  @doc """
  Fast-tool binaries bundled into the release (`priv/bin`). Returns `""` when
  the app has no priv dir (e.g. in some dev/test layouts).
  """
  @spec bundled_dir() :: String.t()
  def bundled_dir do
    case :code.priv_dir(:catalyst) do
      {:error, _} -> ""
      dir -> Path.join(to_string(dir), "bin")
    end
  end

  # Tools with a custom `:hint` are built, not brewed (catalyst-input).
  defp install_hint(_tool, %{hint: hint}), do: hint

  defp install_hint(tool, spec) do
    "fast-tool #{inspect(tool)} (#{spec.exe}) not found on PATH or in #{bin_dir()}. " <>
      "Install it (e.g. `brew install #{spec.brew}`). " <>
      "Releases: https://github.com/#{spec.repo}/releases"
  end
end
