defmodule Catalyst.ComparisonTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [wait_until: 1]
  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Catalyst.Comparison
  alias Catalyst.Comparison.Store
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

  test "lane configuration updates the durable comparison manifest", %{source: source} do
    assert {:ok, comparison} =
             Comparison.create(source, ["gpt-5.6-sol", "gpt-5.6-terra"])

    lane = hd(comparison["lanes"])
    model = Catalyst.LLM.OpenAICodex.model("gpt-5.6-luna")
    prompt = Comparison.system_prompt("Review only correctness.")

    assert {:ok, updated} =
             Comparison.configure_lane(
               comparison["id"],
               lane["id"],
               model: model,
               provider: model.api,
               system_prompt: prompt,
               opts: [reasoning_effort: "high", workflow: "review"]
             )

    assert {:ok, configured} = Comparison.lane(updated, lane["id"])
    assert configured["model_id"] == "gpt-5.6-luna"
    assert configured["system_prompt"] == prompt
    assert configured["reasoning_effort"] == "high"
    assert configured["workflow"] == "review"
    assert {:ok, ^updated} = Comparison.get(comparison["id"])
  end

  test "invalid manifests are rejected and omitted from listings", %{comparisons: comparisons} do
    id = "malformed"
    directory = Path.join(comparisons, id)
    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, "manifest.json"),
      Jason.encode!(%{"version" => 1, "id" => id})
    )

    assert {:error, {:invalid_comparison_manifest, _manifest}} = Comparison.get(id)
    assert Comparison.list() == []
    assert {:error, {:invalid_comparison_manifest, _manifest}} = Store.persist(%{"id" => id})
  end

  test "a crashed dispatch remains attributable to its lane", %{source: source} do
    assert {:ok, comparison} =
             Comparison.create(source, ["gpt-5.6-sol", "gpt-5.6-terra"])

    lane = hd(comparison["lanes"])
    :ok = Manager.stop(lane["session_id"])
    wait_until(fn -> Manager.whereis(lane["session_id"]) == :error end)
    owner = self()

    _stub =
      start_supervised!({
        Task,
        fn ->
          {:ok, _owner} = Registry.register(Catalyst.Session.Registry, lane["session_id"], nil)
          send(owner, :lane_stub_ready)

          receive do
            {:"$gen_call", _from, {:submit, _message}} -> exit(:dispatch_crashed)
          end
        end
      })

    assert_receive :lane_stub_ready

    capture_log(fn ->
      assert {:ok, outcomes} =
               Comparison.dispatch(comparison["id"], [lane["id"]], "Compare this")

      lane_id = lane["id"]
      assert %{^lane_id => {:error, _reason}} = outcomes
      refute Map.has_key?(outcomes, "unknown")
    end)
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
