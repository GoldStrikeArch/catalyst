defmodule CatalystWeb.Workbench.WorkspaceTest do
  use ExUnit.Case, async: true

  alias CatalystWeb.Workbench.Workspace

  setup do
    root =
      Path.join(System.tmp_dir!(), "catalyst_workbench_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/example.ex"), "defmodule Example do\nend\n")
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, ".git/config"), "hidden")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "lists, reads, and atomically saves regular workspace files", %{root: root} do
    assert {:ok, ["lib/example.ex"]} = Workspace.list_files(root)

    assert {:ok, %{path: "lib/example.ex", content: content}} =
             Workspace.read_file(root, "lib/example.ex")

    assert content =~ "defmodule Example"
    assert :ok = Workspace.write_file(root, "lib/example.ex", "updated\n")
    assert File.read!(Path.join(root, "lib/example.ex")) == "updated\n"
  end

  test "rejects traversal and symlink escapes", %{root: root} do
    outside = Path.join(Path.dirname(root), "outside-#{System.unique_integer([:positive])}.txt")
    File.write!(outside, "secret")
    File.ln_s!(outside, Path.join(root, "escape.txt"))

    assert {:error, :unsafe_workspace_path} = Workspace.read_file(root, "../outside.txt")
    assert {:error, :unsafe_workspace_path} = Workspace.read_file(root, "escape.txt")
    assert {:ok, files} = Workspace.list_files(root)
    refute "escape.txt" in files
  end
end
