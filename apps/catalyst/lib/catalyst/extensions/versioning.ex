defmodule Catalyst.Extensions.Versioning do
  @moduledoc """
  Best-effort git versioning of the extensions directory so self-modifications can
  be rolled back. All operations degrade gracefully when `git` isn't available.
  """

  # Commit as a fixed identity so a fresh repo can commit without global git config.
  @id ["-c", "user.name=Catalyst", "-c", "user.email=catalyst@localhost"]

  @doc "Whether git is on PATH."
  @spec available?() :: boolean()
  def available?, do: System.find_executable("git") != nil

  @doc "Initialise a repo in `dir` (with an empty root commit) if needed."
  @spec ensure_repo(Path.t()) :: :ok
  def ensure_repo(dir) do
    if available?() and not File.dir?(Path.join(dir, ".git")) do
      File.mkdir_p!(dir)
      git(dir, ["init", "-q"])
      git(dir, @id ++ ["commit", "-q", "--allow-empty", "-m", "init"])
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Stage everything and commit with `message`.

  A clean tree (e.g. re-installing byte-identical source) is a no-op `:ok`, not
  an empty commit: `git revert HEAD` of an empty commit fails, so an empty
  commit would break the next `rollback/1`.
  """
  @spec commit(Path.t(), String.t()) :: :ok | {:error, term()}
  def commit(dir, message) do
    case repo?(dir) do
      false ->
        {:error, :no_git}

      true ->
        git(dir, ["add", "-A"])
        commit_staged(dir, message)
    end
  end

  defp commit_staged(dir, message) do
    case git(dir, ["status", "--porcelain"]) do
      {"", 0} ->
        :ok

      _dirty ->
        case git(dir, @id ++ ["commit", "-q", "-m", message]) do
          {_out, 0} -> :ok
          {out, code} -> {:error, {code, out}}
        end
    end
  end

  @doc """
  Revert the most recent commit (undo the last change).

  On failure, `git revert --abort` is run (best effort) before returning the
  error so a half-done revert can't leave sequencer state that wedges every
  later rollback with "revert already in progress".
  """
  @spec rollback(Path.t()) :: :ok | {:error, term()}
  def rollback(dir) do
    case repo?(dir) do
      false ->
        {:error, :no_git}

      true ->
        case git(dir, @id ++ ["revert", "--no-edit", "HEAD"]) do
          {_out, 0} ->
            :ok

          {out, code} ->
            git(dir, ["revert", "--abort"])
            {:error, {code, out}}
        end
    end
  end

  defp repo?(dir), do: available?() and File.dir?(Path.join(dir, ".git"))

  defp git(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)
end
