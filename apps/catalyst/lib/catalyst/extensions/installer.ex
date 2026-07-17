defmodule Catalyst.Extensions.Installer do
  @moduledoc """
  Shared write → compile/load → commit pipeline for the self-modification tools
  (`develop_tool`, `install_extension`). On a failed load the file's prior
  content is restored (or a brand-new file removed) and nothing is committed,
  so the extensions repo's HEAD always matches the loaded state — which is what
  `rollback_extension`'s `git revert HEAD` relies on.

  Self-modification is full code execution in the host VM by design (the user's
  own agent on their machine), but it can be switched off — e.g. when running
  the agent against untrusted repos, where prompt injection could ask it to
  install hostile code: set `CATALYST_DISABLE_SELF_MOD=1` or
  `config :catalyst, :allow_self_modification, false`. `install/3` then refuses
  with a tagged error instead of writing or compiling anything.
  """

  alias Catalyst.Extensions
  alias Catalyst.Extensions.Versioning

  @doc """
  Write `source` as `<sanitized name>.ex` in the extensions dir, load it, and
  commit. Returns `{:ok, summary}` (with `:path` added) or `{:error, reason}`.
  """
  def install(name, source, commit_prefix \\ "install") do
    case enabled?() do
      true ->
        do_install(name, source, commit_prefix)

      false ->
        {:error,
         "self-modification is disabled on this machine " <>
           "(CATALYST_DISABLE_SELF_MOD / config :catalyst, :allow_self_modification)"}
    end
  end

  @doc "Whether the self-modification tools may write and compile code (default: true)."
  def enabled? do
    System.get_env("CATALYST_DISABLE_SELF_MOD") not in ~w(1 true) and
      Application.get_env(:catalyst, :allow_self_modification, true)
  end

  defp do_install(name, source, commit_prefix) do
    dir = Extensions.dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, sanitize(name) <> ".ex")
    existed = File.exists?(path)
    backup = if existed, do: File.read!(path), else: nil

    File.write!(path, source)

    case Extensions.load_file(path) do
      {:ok, summary} ->
        Versioning.commit(dir, "#{commit_prefix} #{summary.owner}")
        {:ok, Map.put(summary, :path, path)}

      {:error, reason} ->
        # Restore the prior version (or remove a brand-new broken file) so a
        # failed install leaves neither broken source nor an uncommitted diff.
        if existed, do: File.write!(path, backup), else: File.rm(path)
        {:error, reason}
    end
  end

  @doc "File-safe extension name."
  def sanitize(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "ext_#{System.unique_integer([:positive])}"
      ok -> ok
    end
  end
end
