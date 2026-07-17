defmodule Catalyst.Extensions.Versioning do
  @moduledoc """
  Best-effort git versioning of the extensions directory so self-modifications can
  be rolled back. All operations degrade gracefully when `git` isn't available.
  """

  # Commit as a fixed identity so a fresh repo can commit without global git config.
  @id ["-c", "user.name=Catalyst", "-c", "user.email=catalyst@localhost"]

  @doc "Whether git is on PATH."
  def available?, do: System.find_executable("git") != nil

  @doc "Initialise a repo in `dir` (with an empty root commit) if needed."
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

  @doc "Stage everything and commit with `message`."
  def commit(dir, message) do
    if repo?(dir) do
      git(dir, ["add", "-A"])

      case git(dir, @id ++ ["commit", "-q", "--allow-empty", "-m", message]) do
        {_out, 0} -> :ok
        {out, code} -> {:error, {code, out}}
      end
    else
      {:error, :no_git}
    end
  end

  @doc "Revert the most recent commit (undo the last change)."
  def rollback(dir) do
    if repo?(dir) do
      case git(dir, @id ++ ["revert", "--no-edit", "HEAD"]) do
        {_out, 0} -> :ok
        {out, code} -> {:error, {code, out}}
      end
    else
      {:error, :no_git}
    end
  end

  defp repo?(dir), do: available?() and File.dir?(Path.join(dir, ".git"))

  defp git(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)
end
