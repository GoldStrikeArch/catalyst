defmodule Catalyst.Workflow.StoreTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.Workflow.{Store, Template}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_workflow_store_#{System.unique_integer([:positive, :monotonic])}"
      )

    previous = Application.fetch_env(:catalyst, :workflows_dir)
    Application.put_env(:catalyst, :workflows_dir, root)

    on_exit(fn ->
      restore_env(:workflows_dir, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "atomically saves, fetches, lists, replaces, and deletes user templates" do
    assert {:error, :not_found} = Store.fetch("mine")
    assert {:ok, saved} = Store.save(attrs("mine", "Mine"))
    assert {:ok, ^saved} = Store.fetch("mine")
    assert File.read!(Path.join(Store.directory(), "mine.json")) |> Jason.decode!()

    assert {:ok, templates} = Store.list()
    assert Enum.map(templates, & &1.id) == ~w(research build-review secure-build mine)

    assert {:ok, replaced} = Store.save(attrs("mine", "Replacement"))
    assert replaced.name == "Replacement"
    assert {:ok, ^replaced} = Store.fetch("mine")

    assert :ok = Store.delete("mine")
    assert :ok = Store.delete("mine")
    assert {:error, :not_found} = Store.fetch("mine")
  end

  test "built-ins are fetched but cannot be overwritten or deleted" do
    assert {:ok, %Template{id: "research"}} = Store.fetch("research")

    assert {:error, {:immutable_builtin, "research"}} =
             Store.save(attrs("research", "Shadow"))

    assert {:error, {:immutable_builtin, "research"}} = Store.delete("research")
  end

  test "rejects traversal ids before touching the filesystem" do
    assert {:error, {:invalid, "id", :invalid_id}} = Store.fetch("../escape")
    assert {:error, {:invalid, "id", :invalid_id}} = Store.delete("../escape")
    refute File.exists?(Store.directory())
  end

  test "returns tagged errors for corrupt documents and filename mismatches" do
    File.mkdir_p!(Store.directory())
    File.write!(Path.join(Store.directory(), "broken.json"), "{")

    assert {:error, {:decode_failed, _path, _reason}} = Store.fetch("broken")

    File.write!(
      Path.join(Store.directory(), "wrong.json"),
      attrs("other", "Other") |> Jason.encode!()
    )

    assert {:error, {:decode_failed, _path, :id_filename_mismatch}} = Store.fetch("wrong")
  end

  test "a rejected replacement leaves the previous complete document intact" do
    assert {:ok, original} = Store.save(attrs("mine", "Original"))

    invalid = attrs("mine", String.duplicate("x", 121))
    assert {:error, {:invalid, "name", {:too_long, 120}}} = Store.save(invalid)
    assert {:ok, ^original} = Store.fetch("mine")
  end

  defp attrs(id, name) do
    %{
      "version" => 1,
      "id" => id,
      "name" => name,
      "description" => "A user workflow.",
      "stages" => [
        %{
          "id" => "work",
          "name" => "Work",
          "prompt" => "Complete the goal.",
          "preset" => "balanced",
          "tool_profile" => "workspace",
          "inputs" => ["goal"],
          "artifact" => "result",
          "timeout_ms" => 60_000,
          "max_attempts" => 2
        }
      ]
    }
  end
end
