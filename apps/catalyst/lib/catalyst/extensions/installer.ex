defmodule Catalyst.Extensions.Installer do
  @moduledoc """
  Shared write → compile/load → commit pipeline for the self-modification tools
  (`develop_tool`, `install_extension`). On a failed load the file's prior
  content is restored — and, for an update of an existing extension, RE-LOADED,
  since a partial multi-module compile may have redefined modules in the VM
  before failing (a brand-new file is removed instead; `Catalyst.Extensions`
  purges its partial modules). Nothing is committed on failure, so the
  extensions repo's HEAD matches the loaded state — which is what
  `rollback_extension`'s history walk relies on. The one tolerated divergence:
  if a successful install fails to git-commit (e.g. git missing or wedged), the
  install is kept and the summary flags it as unversioned (`versioned: false` +
  `:warning`) — rollback simply can't revert that change.

  Self-modification is full code execution in the host VM by design (the user's
  own agent on their machine), but it can be switched off — e.g. when running
  the agent against untrusted repos, where prompt injection could ask it to
  install hostile code: set `CATALYST_DISABLE_SELF_MOD=1` or
  `config :catalyst, :allow_self_modification, false`. `install/3` then refuses
  with a tagged error instead of writing or compiling anything.
  """

  require Logger

  alias Catalyst.Extensions
  alias Catalyst.Extensions.Versioning
  alias Catalyst.Files.AtomicWrite

  @doc """
  Write `source` as `<sanitized name>.ex` in the extensions dir, load it, and
  commit. Returns `{:ok, summary}` (with `:path` added) or `{:error, reason}`.
  """
  @spec install(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def install(name, source, commit_prefix \\ "install") do
    case enabled?() do
      true ->
        do_install(name, source, commit_prefix)

      false ->
        # Matchable; render with Catalyst.Extensions.format_error/1.
        {:error, :self_mod_disabled}
    end
  end

  @doc "Whether the self-modification tools may write and compile code (default: true)."
  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env("CATALYST_DISABLE_SELF_MOD") not in ~w(1 true) and
      Application.get_env(:catalyst, :allow_self_modification, true)
  end

  # The whole write → load → commit sequence runs as ONE critical section
  # under the extensions load lock (`Extensions.locked/1`, re-entrant for the
  # inner `load_file`): a concurrent `load_all` can't glob the half-written
  # file, and a concurrent install can't interleave between our write and our
  # commit. The commit itself is scoped to this file (`commit_paths/3`), so
  # someone else's uncommitted edits aren't swept into our history entry.
  defp do_install(name, source, commit_prefix) do
    Extensions.locked(fn ->
      dir = Extensions.dir()
      File.mkdir_p!(dir)
      # The repo is normally ensured by the boot-time load path, but that is
      # skipped in safe mode — and an install must still be committable then.
      # Idempotent and cheap once the repo exists.
      Versioning.ensure_repo(dir)
      path = Path.join(dir, sanitize(name) <> ".ex")
      existed = File.exists?(path)
      backup = if existed, do: File.read!(path), else: nil

      AtomicWrite.write!(path, source)

      case Extensions.load_file(path) do
        {:ok, summary} ->
          commit_install(dir, path, summary, commit_prefix)

        {:error, reason} ->
          # Restore the prior version (or remove a brand-new broken file) so a
          # failed install leaves neither broken source nor an uncommitted diff.
          restore_prior(path, existed, backup)
          {:error, reason}
      end
    end)
  end

  # A versioning failure must not undo a successful install — the code is live
  # and the file is written. But the change has no commit, so rollback can't
  # revert it: flag the summary so the agent/user knows.
  defp commit_install(dir, path, summary, commit_prefix) do
    case Versioning.commit_paths(dir, [path], "#{commit_prefix} #{summary.owner}") do
      :ok ->
        {:ok, Map.put(summary, :path, path)}

      {:error, reason} ->
        Logger.warning("[installer] could not git-commit #{path}: #{inspect(reason)}")

        warning =
          "the change was NOT git-versioned (#{inspect(reason)}) — " <>
            "rollback_extension cannot revert it"

        {:ok,
         summary
         |> Map.put(:path, path)
         |> Map.put(:versioned, false)
         |> append_warning(warning)}
    end
  end

  defp append_warning(summary, warning) do
    Map.update(summary, :warning, warning, fn
      existing when is_binary(existing) -> existing <> "; " <> warning
      _other -> warning
    end)
  end

  # On a failed load over an existing file, restoring the bytes on disk is not
  # enough: Code.compile_file/1 defines modules sequentially, so a partial
  # compile may have redefined some of the prior version's modules before
  # failing. Re-load the restored source so the VM runs the prior definitions
  # again. (For a brand-new file, Extensions purges the partial modules itself
  # and there is nothing to re-load.)
  defp restore_prior(path, true = _existed, backup) do
    AtomicWrite.write!(path, backup)

    case Extensions.load_file(path) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[installer] failed to re-load the restored prior version of #{path} " <>
            "after a failed install: #{inspect(reason)} — the VM may still be " <>
            "running modules from the failed attempt until the file is reloaded"
        )
    end
  end

  defp restore_prior(path, false = _existed, _backup), do: File.rm(path)

  @doc "File-safe extension name."
  @spec sanitize(String.t()) :: String.t()
  def sanitize(name) do
    name
    |> Extensions.sanitize_owner()
    |> case do
      "" -> "ext_#{System.unique_integer([:positive])}"
      ok -> ok
    end
  end
end
