defmodule Catalyst.ComparisonTest do
  use ExUnit.Case, async: false

  alias Catalyst.Comparison
  alias Catalyst.Session.Manager

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "catalyst_comparison_#{System.unique_integer([:positive])}"
      )

    source = Path.join(tmp, "source")
    comparisons = Path.join(tmp, "comparisons")
    workspaces = Path.join(tmp, "workspaces")
    sessions = Path.join(tmp, "sessions")
    File.mkdir_p!(source)

    previous = %{
      comparisons: Application.get_env(:catalyst, :comparisons_root),
      workspaces: Application.get_env(:catalyst, :workspaces_root),
      sessions: Application.get_env(:catalyst, :sessions_root)
    }

    Application.put_env(:catalyst, :comparisons_root, comparisons)
    Application.put_env(:catalyst, :workspaces_root, workspaces)
    Application.put_env(:catalyst, :sessions_root, sessions)

    git!(source, ["init", "-b", "main"])
    File.write!(Path.join(source, ".gitignore"), "ignored.txt\n")
    File.write!(Path.join(source, "tracked.txt"), "committed\n")
    git!(source, ["add", ".gitignore", "tracked.txt"])

    git!(source, [
      "-c",
      "user.name=Catalyst",
      "-c",
      "user.email=test@example.com",
      "commit",
      "-m",
      "initial"
    ])

    File.write!(Path.join(source, "tracked.txt"), "modified\n")
    File.write!(Path.join(source, "untracked.txt"), "untracked\n")
    File.write!(Path.join(source, "ignored.txt"), "ignored\n")

    on_exit(fn ->
      Comparison.list()
      |> Enum.flat_map(& &1["lanes"])
      |> Enum.each(&Manager.stop(&1["session_id"]))

      restore(:comparisons_root, previous.comparisons)
      restore(:workspaces_root, previous.workspaces)
      restore(:sessions_root, previous.sessions)
      File.rm_rf!(tmp)
    end)

    {:ok, source: source, comparisons: comparisons, tmp: tmp}
  end

  test "creates independent clones from one dirty snapshot", %{source: source} do
    assert {:ok, comparison} =
             Comparison.create(source, ["gpt-5.6-sol", "gpt-5.6-terra"])

    assert length(comparison["lanes"]) == 2
    assert comparison["lanes"] |> Enum.map(& &1["snapshot_id"]) |> Enum.uniq() |> length() == 1

    Enum.each(comparison["lanes"], fn lane ->
      assert File.read!(Path.join(lane["cwd"], "tracked.txt")) == "modified\n"
      assert File.read!(Path.join(lane["cwd"], "untracked.txt")) == "untracked\n"
      refute File.exists?(Path.join(lane["cwd"], "ignored.txt"))
      assert File.dir?(Path.join(lane["cwd"], ".git"))
      assert git!(lane["cwd"], ["remote"]) == ""
    end)

    [first, second] = comparison["lanes"]
    refute first["cwd"] == second["cwd"]
    assert {:ok, _pid} = Comparison.ensure_session(first)
    assert {:ok, _pid} = Comparison.ensure_session(second)
  end

  test "a later lane captures a fresh source snapshot", %{source: source} do
    assert {:ok, comparison} =
             Comparison.create(source, ["gpt-5.6-sol", "gpt-5.6-terra"])

    File.write!(Path.join(source, "tracked.txt"), "changed later\n")

    assert {:ok, updated} = Comparison.add_lane(comparison["id"], "gpt-5.6-luna")
    added = List.last(updated["lanes"])

    refute added["snapshot_id"] == hd(comparison["lanes"])["snapshot_id"]
    assert File.read!(Path.join(added["cwd"], "tracked.txt")) == "changed later\n"
    assert map_size(updated["snapshots"]) == 2
  end

  test "a failed later lane removes its captured snapshot", %{
    source: source,
    comparisons: comparisons,
    tmp: tmp
  } do
    assert {:ok, comparison} =
             Comparison.create(source, ["gpt-5.6-sol", "gpt-5.6-terra"])

    blocked = Path.join(tmp, "blocked-workspaces")
    File.write!(blocked, "not a directory")
    Application.put_env(:catalyst, :workspaces_root, blocked)

    snapshots = Path.join([comparisons, comparison["id"], "snapshots", "*"])
    assert length(Path.wildcard(snapshots)) == 1

    assert {:error, {:lane_provision_failed, _reason}} =
             Comparison.add_lane(comparison["id"], "gpt-5.6-luna")

    assert length(Path.wildcard(snapshots)) == 1
  end

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git exited #{status}: #{output}")
    end
  end

  defp restore(key, nil), do: Application.delete_env(:catalyst, key)
  defp restore(key, value), do: Application.put_env(:catalyst, key, value)
end
