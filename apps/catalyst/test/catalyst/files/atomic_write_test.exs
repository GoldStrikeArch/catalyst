defmodule Catalyst.Files.AtomicWriteTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [band: 2]

  alias Catalyst.Files.AtomicWrite

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_atomic_write_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "replaces a file, preserves its mode, and leaves no temp file", %{root: root} do
    path = Path.join(root, "document.txt")
    File.write!(path, "old")
    File.chmod!(path, 0o640)

    assert :ok = AtomicWrite.write(path, ["new", " content"])
    assert File.read!(path) == "new content"
    assert file_mode(path) == 0o640
    assert temp_files(root, path) == []
  end

  test "an explicit 0600 mode is applied to a new file", %{root: root} do
    path = Path.join(root, "secret.json")

    assert :ok = AtomicWrite.write(path, ~s({"token":"secret"}), mode: 0o600)
    assert File.read!(path) == ~s({"token":"secret"})
    assert file_mode(path) == 0o600
  end

  test "writes through a symlink without replacing the link", %{root: root} do
    target = Path.join(root, "target.txt")
    link = Path.join(root, "link.txt")
    File.write!(target, "old")
    File.ln_s!(target, link)

    assert :ok = AtomicWrite.write(link, "new")
    assert File.read!(target) == "new"
    assert {:ok, _target} = File.read_link(link)
  end

  test "returns an error and cleans up when replacement fails", %{root: root} do
    path = Path.join(root, "occupied")
    File.mkdir!(path)

    assert {:error, _reason} = AtomicWrite.write(path, "cannot replace a directory")
    assert File.dir?(path)
    assert temp_files(root, path) == []
  end

  test "concurrent replacements use independent temp files", %{root: root} do
    path = Path.join(root, "shared.txt")
    payloads = Enum.map(1..20, &String.duplicate("payload-#{&1}\n", 100))

    results =
      Task.async_stream(payloads, &AtomicWrite.write(path, &1),
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert File.read!(path) in payloads
    assert temp_files(root, path) == []
  end

  defp file_mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    band(mode, 0o7777)
  end

  defp temp_files(root, path) do
    Path.wildcard(Path.join(root, ".#{Path.basename(path)}.catalyst-*.tmp"))
  end
end
