defmodule Catalyst.Extensions.Versioning do
  @moduledoc """
  Best-effort git versioning of the extensions directory so self-modifications can
  be rolled back. All operations degrade gracefully when `git` isn't available.

  Git is sandboxed against the user's environment in two ways:

    * every history-writing command runs with `-c` overrides (`@id`) — a fixed
      identity, `commit.gpgsign=false`, and `core.hooksPath=` — so a global or
      repo-local gpg/pinentry setup can't hang a commit waiting for a passphrase
      and user hooks never run during self-modification commits;
    * every invocation goes through `Catalyst.Tools.Exec.collect/3` with a
      deadline, so a wedged git (lock contention, credential helpers, network
      filesystems) returns `{:error, :timeout}` instead of blocking the
      Extensions server or an install forever.
  """

  require Logger

  alias Catalyst.Tools.Exec

  # Commit as a fixed identity so a fresh repo can commit without global git
  # config; force signing OFF and disable hooks (empty core.hooksPath) so user
  # config can't hang on pinentry or run hook scripts mid-install/rollback.
  @id [
    "-c",
    "user.name=Catalyst",
    "-c",
    "user.email=catalyst@localhost",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "core.hooksPath="
  ]

  # Per-command deadline (Exec.collect kills the child at the deadline):
  # generous for local repo operations, short enough not to wedge a caller.
  @timeout 15_000

  # How far back rollback/1 scans for a not-yet-reverted change.
  @log_window 50

  @doc "Whether git is on PATH."
  @spec available?() :: boolean()
  def available?, do: System.find_executable("git") != nil

  @doc "Initialise a repo in `dir` (with an empty root commit) if needed."
  @spec ensure_repo(Path.t()) :: :ok
  def ensure_repo(dir) do
    case available?() and not File.dir?(Path.join(dir, ".git")) do
      false ->
        :ok

      true ->
        with :ok <- File.mkdir_p(dir),
             {:ok, _output, 0} <- git(dir, ["init", "-q"]),
             {:ok, _output, 0} <-
               git(dir, @id ++ ["commit", "-q", "--allow-empty", "-m", "init"]) do
          :ok
        else
          {:error, reason} ->
            Logger.warning("[extensions] could not initialise versioning: #{inspect(reason)}")
            :ok
        end
    end
  end

  @doc """
  Stage everything and commit with `message`.

  A clean tree (e.g. re-installing byte-identical source) is a no-op `:ok`, not
  an empty commit: `git revert` of an empty commit fails, so an empty commit
  would break the next `rollback/1`.
  """
  @spec commit(Path.t(), String.t()) :: :ok | {:error, term()}
  def commit(dir, message) do
    case repo?(dir) do
      false ->
        {:error, :no_git}

      true ->
        case git(dir, ["add", "-A"]) do
          {:ok, _output, 0} -> commit_staged(dir, message)
          {:error, _reason} = error -> error
        end
    end
  end

  defp commit_staged(dir, message) do
    case git(dir, ["status", "--porcelain"]) do
      {:ok, "", 0} ->
        :ok

      {:ok, _dirty, 0} ->
        case git(dir, @id ++ ["commit", "-q", "-m", message]) do
          {:ok, _output, 0} -> :ok
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Stage only `paths` and commit. The installer's scoped variant of `commit/2`:
  an unrelated dirty file (a hand-edit in progress, another extension's
  half-written source) stays uncommitted instead of being swept into this
  change's commit — which would skew what `rollback/1` reverts.
  """
  @spec commit_paths(Path.t(), [Path.t()], String.t()) :: :ok | {:error, term()}
  def commit_paths(dir, paths, message) do
    case repo?(dir) do
      false ->
        {:error, :no_git}

      true ->
        rel =
          paths
          |> Enum.map(&Path.relative_to(&1, dir))
          |> Enum.filter(&stageable_path?(dir, &1))

        case rel do
          [] ->
            :ok

          paths ->
            case git(dir, ["add", "--"] ++ paths) do
              {:ok, _output, 0} -> commit_staged_paths(dir, paths, message)
              {:error, _reason} = error -> error
            end
        end
    end
  end

  # `git add -- missing-new-file` rejects the whole command. A lifecycle rename
  # can legitimately mention such a path when the source was loaded directly
  # and had never been committed, so stage only files that exist now or are
  # already tracked (tracked deletions still need to be staged).
  defp stageable_path?(dir, path) do
    File.exists?(Path.join(dir, path)) or tracked_path?(dir, path)
  end

  defp tracked_path?(dir, path) do
    case git(dir, ["ls-files", "--error-unmatch", "--", path]) do
      {:ok, _output, 0} -> true
      {:error, _reason} -> false
    end
  end

  # Commit the index only when something is actually staged (exit 1 from
  # `diff --cached --quiet` = differences): a byte-identical reinstall stays a
  # no-op `:ok` for the same empty-commit reason as `commit/2`.
  defp commit_staged_paths(dir, paths, message) do
    case git(dir, ["diff", "--cached", "--quiet", "--"] ++ paths, [0, 1]) do
      {:ok, _output, 0} ->
        :ok

      {:ok, _output, 1} ->
        # Supplying a pathspec makes git commit ONLY these paths from the index;
        # unrelated changes that were already staged stay staged for their owner.
        case git(dir, @id ++ ["commit", "-q", "-m", message, "--"] ++ paths) do
          {:ok, _output, 0} -> :ok
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Undo the most recent extension change that has not already been reverted.

  A naive `git revert HEAD` is a toggle: a second rollback reverts the revert,
  silently re-installing the bad code. Instead the recent log is scanned
  newest-first, pairing each `Revert "…"` commit with the older commit it
  undid; the first non-revert commit with no pending revert is the target, so
  repeated rollbacks walk backwards through the history of changes (LIFO),
  never forwards. With nothing left to revert in the scanned window,
  `{:error, :nothing_to_rollback}` is returned.

  On a failed revert (e.g. a conflict), `git revert --abort` is run (best
  effort) before returning the error so a half-done revert can't leave
  sequencer state that wedges every later rollback with "revert already in
  progress".
  """
  @spec rollback(Path.t()) :: :ok | {:error, term()}
  def rollback(dir) do
    case repo?(dir) do
      false ->
        {:error, :no_git}

      true ->
        with {:ok, commits} <- recent_commits(dir),
             {:ok, hash} <- rollback_target(commits) do
          do_revert(dir, hash)
        end
    end
  end

  @doc """
  Like `rollback/1`, but scoped to one extension: undo the most recent
  not-yet-reverted commit that touched `file` (or its `.disabled` variant, so
  disable/enable renames stay in scope). Other extensions' changes are left
  alone. Best effort: a commit that spanned several files (e.g. a `git add -A`
  install picking up unrelated edits) is reverted whole.
  """
  @spec rollback_file(Path.t(), Path.t()) :: :ok | {:error, term()}
  def rollback_file(dir, file) do
    case repo?(dir) do
      false ->
        {:error, :no_git}

      true ->
        # Normalize to the enabled name so a currently-disabled extension's
        # pre-disable history is still in scope.
        rel =
          file
          |> Path.expand()
          |> Path.relative_to(Path.expand(dir))
          |> String.replace_suffix(".disabled", "")

        with {:ok, commits} <- recent_commits(dir, [rel, rel <> ".disabled"]),
             {:ok, hash} <- rollback_target(commits) do
          do_revert(dir, hash)
        end
    end
  end

  # ---- rollback internals ----------------------------------------------------

  defp recent_commits(dir, paths \\ []) do
    pathspec =
      case paths do
        [] -> []
        paths -> ["--" | paths]
      end

    case git(dir, ["log", "--format=%H%x09%s", "-n", Integer.to_string(@log_window)] ++ pathspec) do
      {:ok, out, 0} ->
        commits =
          out
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(line, "\t", parts: 2) do
              [hash, subject] -> {hash, subject}
              [hash] -> {hash, ""}
            end
          end)

        {:ok, commits}

      {:error, _reason} = error ->
        error
    end
  end

  # Newest-first scan: a `Revert "x"` pushes a pending revert for subject x; a
  # non-revert commit with a pending revert for its subject consumes one and is
  # skipped (it has already been undone); the first non-revert commit with no
  # pending revert is the next change to undo. Pending reverts are counted PER
  # SUBJECT, not globally, so reverting A can't "use up" a pending revert of B
  # in an interleaved history.
  defp rollback_target(commits) do
    commits
    |> Enum.reduce_while(%{}, fn {hash, subject}, pending ->
      case revert_subject(subject) do
        {:ok, inner} ->
          {:cont, Map.update(pending, inner, 1, &(&1 + 1))}

        :not_a_revert ->
          case Map.get(pending, subject, 0) do
            0 -> {:halt, {:target, hash}}
            n -> {:cont, Map.put(pending, subject, n - 1)}
          end
      end
    end)
    |> case do
      {:target, hash} -> {:ok, hash}
      _pending_map -> {:error, :nothing_to_rollback}
    end
  end

  # `git revert` titles its commit `Revert "<original subject>"`. A nested
  # revert-of-a-revert therefore pushes the inner `Revert "x"` subject itself,
  # which pairs with the original revert commit — the bookkeeping nests for free.
  defp revert_subject("Revert \"" <> rest) do
    case String.split_at(rest, -1) do
      {inner, "\""} -> {:ok, inner}
      _ -> :not_a_revert
    end
  end

  defp revert_subject(_subject), do: :not_a_revert

  defp do_revert(dir, hash) do
    case git(dir, @id ++ ["revert", "--no-edit", hash]) do
      {:ok, _output, 0} ->
        :ok

      {:error, _reason} = error ->
        # Conflict (or any failure): abort so no sequencer state survives.
        git(dir, ["revert", "--abort"])
        error
    end
  end

  # ---- plumbing ---------------------------------------------------------------

  defp repo?(dir), do: available?() and File.dir?(Path.join(dir, ".git"))

  # All git calls run through Exec.collect/3 (port + absolute deadline) so a
  # hung git can't block the caller. Expected statuses are explicitly tagged;
  # every other exit and transport failure has one `{:error, reason}` shape.
  defp git(dir, args, expected_statuses \\ [0]) do
    case System.find_executable("git") do
      nil ->
        {:error, :no_git}

      git ->
        case Exec.collect(git, args, cwd: dir, timeout: @timeout) do
          {:ok, %{out: out, status: status}} ->
            case status in expected_statuses do
              true -> {:ok, out, status}
              false -> {:error, {status, out}}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
