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
