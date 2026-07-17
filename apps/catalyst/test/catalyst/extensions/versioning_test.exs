defmodule Catalyst.Extensions.VersioningTest do
  # async: false — shells out to real git in tmp dirs (same pattern as
  # self_mod_test's versioning round-trip tests).
  use ExUnit.Case, async: false

  alias Catalyst.Extensions.Versioning

  defp tmp_repo!(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "catalyst_ver_#{label}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    assert :ok = Versioning.ensure_repo(dir)
    dir
  end

  @tag :git
  test "commit_paths stages only the named file, leaving unrelated edits uncommitted" do
    if Versioning.available?() do
      dir = tmp_repo!("scoped")
      mine = Path.join(dir, "mine.ex")
      other = Path.join(dir, "other.ex")
      File.write!(mine, "# mine v1\n")
      File.write!(other, "# other, mid-edit\n")

      assert :ok = Versioning.commit_paths(dir, [mine], "install mine")

      # `other.ex` was dirty during the commit but is NOT part of it.
      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: dir)
      assert status =~ "other.ex"
      refute status =~ "mine.ex"

      {shown, 0} = System.cmd("git", ["show", "--name-only", "--format=%s", "HEAD"], cd: dir)
      assert shown =~ "install mine"
      assert shown =~ "mine.ex"
      refute shown =~ "other.ex"

      # Byte-identical re-commit is a no-op, not an empty commit.
      assert :ok = Versioning.commit_paths(dir, [mine], "install mine again")
      {subject, 0} = System.cmd("git", ["log", "-1", "--format=%s"], cd: dir)
      assert String.trim(subject) == "install mine"
    end
  end

  @tag :git
  test "commit_paths ignores an untracked missing rename source" do
    if Versioning.available?() do
      dir = tmp_repo!("untracked_rename")
      missing_source = Path.join(dir, "direct_load.ex")
      disabled = missing_source <> ".disabled"
      File.write!(disabled, "# disabled direct load\n")

      assert :ok =
               Versioning.commit_paths(
                 dir,
                 [missing_source, disabled],
                 "disable direct_load"
               )

      {shown, 0} = System.cmd("git", ["show", "--name-only", "--format=", "HEAD"], cd: dir)
      assert shown =~ "direct_load.ex.disabled"
      refute shown =~ "\ndirect_load.ex\n"
    end
  end

  @tag :git
  test "commit_paths excludes changes that were already staged" do
    if Versioning.available?() do
      dir = tmp_repo!("prestaged")
      mine = Path.join(dir, "mine.ex")
      staged = Path.join(dir, "staged.ex")

      File.write!(staged, "# belongs to someone else\n")
      {_, 0} = System.cmd("git", ["add", "--", "staged.ex"], cd: dir)
      File.write!(mine, "# mine\n")

      assert :ok = Versioning.commit_paths(dir, [mine], "install mine")

      {shown, 0} = System.cmd("git", ["show", "--name-only", "--format=", "HEAD"], cd: dir)
      assert shown =~ "mine.ex"
      refute shown =~ "staged.ex"

      # The unrelated file is still staged exactly as it was before our commit.
      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: dir)
      assert status =~ "A  staged.ex"
      refute status =~ "mine.ex"
    end
  end

  @tag :git
  test "repeated rollbacks walk the change history LIFO instead of toggling" do
    if Versioning.available?() do
      dir = tmp_repo!("lifo")

      File.write!(Path.join(dir, "a.ex"), "a v1")
      assert :ok = Versioning.commit(dir, "install a")
      File.write!(Path.join(dir, "b.ex"), "b v1")
      assert :ok = Versioning.commit(dir, "install b")

      # First rollback undoes the newest change (b)...
      assert :ok = Versioning.rollback(dir)
      assert File.exists?(Path.join(dir, "a.ex"))
      refute File.exists?(Path.join(dir, "b.ex"))

      # ...and the second undoes the next older change (a). The old
      # `git revert HEAD` toggle would instead have reverted the revert here,
      # silently re-installing b.
      assert :ok = Versioning.rollback(dir)
      refute File.exists?(Path.join(dir, "a.ex"))
      refute File.exists?(Path.join(dir, "b.ex"))
    end
  end

  @tag :git
  test "rollback pairs reverts with reinstalls that share a commit subject" do
    if Versioning.available?() do
      dir = tmp_repo!("resubject")
      path = Path.join(dir, "foo.ex")

      # Reinstalling the same extension produces two commits with the SAME
      # subject; the revert-pairing must consume the newest one first.
      File.write!(path, "v1")
      assert :ok = Versioning.commit(dir, "install foo")
      File.write!(path, "v2")
      assert :ok = Versioning.commit(dir, "install foo")

      assert :ok = Versioning.rollback(dir)
      assert File.read!(path) == "v1"

      assert :ok = Versioning.rollback(dir)
      refute File.exists?(path)
    end
  end

  @tag :git
  test "rollback_file reverts only that file's newest change, LIFO per file" do
    if Versioning.available?() do
      dir = tmp_repo!("perfile")
      a = Path.join(dir, "a.ex")
      b = Path.join(dir, "b.ex")

      File.write!(a, "a v1")
      assert :ok = Versioning.commit(dir, "install a")
      File.write!(b, "b v1")
      assert :ok = Versioning.commit(dir, "install b")
      File.write!(a, "a v2")
      assert :ok = Versioning.commit(dir, "update a")

      # Scoped to a: undoes "update a" even though "install b"… is older than
      # it; b is untouched throughout.
      assert :ok = Versioning.rollback_file(dir, a)
      assert File.read!(a) == "a v1"
      assert File.read!(b) == "b v1"

      # Next scoped rollback walks to "install a" (deleting the file)…
      assert :ok = Versioning.rollback_file(dir, a)
      refute File.exists?(a)
      assert File.read!(b) == "b v1"

      # …and then a's history is exhausted while b's is still revertable.
      assert {:error, :nothing_to_rollback} = Versioning.rollback_file(dir, a)
      assert :ok = Versioning.rollback_file(dir, b)
      refute File.exists?(b)
    end
  end

  @tag :git
  test "rollback_file covers a disabled extension's pre-disable history" do
    if Versioning.available?() do
      dir = tmp_repo!("disabledfile")
      path = Path.join(dir, "x.ex")

      File.write!(path, "v1")
      assert :ok = Versioning.commit(dir, "install x")
      File.rename!(path, path <> ".disabled")
      assert :ok = Versioning.commit(dir, "disable x")

      # Passing the .disabled path must still see (and undo) the rename.
      assert :ok = Versioning.rollback_file(dir, path <> ".disabled")
      assert File.exists?(path)
      refute File.exists?(path <> ".disabled")

      # And keep walking into the original install.
      assert :ok = Versioning.rollback_file(dir, path)
      refute File.exists?(path)
    end
  end

  @tag :git
  test "commit succeeds even with commit.gpgsign forced on in the repo-local config" do
    if Versioning.available?() do
      dir = tmp_repo!("gpgsign")

      # Simulate a user whose git config demands signed commits (with a key
      # that can't possibly work) — the `-c commit.gpgsign=false` override
      # must win, or installs would hang on pinentry / fail on a missing key.
      {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "true"], cd: dir)
      {_, 0} = System.cmd("git", ["config", "user.signingkey", "DEADBEEFDEADBEEF"], cd: dir)

      File.write!(Path.join(dir, "a.ex"), "content")
      assert :ok = Versioning.commit(dir, "unsigned by design")

      {log, 0} = System.cmd("git", ["log", "--format=%s", "-n", "1"], cd: dir)
      assert String.trim(log) == "unsigned by design"
    end
  end
end
