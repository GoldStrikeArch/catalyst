defmodule Catalyst.Session.CatalogTest do
  # async: false — swaps the global :session_catalog_path config.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Catalyst.Session.{Catalog, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "catalyst_catalog_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "session_catalog.json")
    Application.put_env(:catalyst, :session_catalog_path, path)

    on_exit(fn ->
      Application.delete_env(:catalyst, :session_catalog_path)
      File.rm_rf!(dir)
    end)

    %{path: path, dir: dir}
  end

  defp create_store!(cwd, id) do
    {:ok, _handle} = Store.open(cwd, id: id)
    :ok
  end

  test "roundtrip: remember, entries, most_recent, lookup, forget" do
    create_store!("/tmp/proj-a", "sess-a")
    create_store!("/tmp/proj-b", "sess-b")

    assert :ok = Catalog.remember("sess-a", "/tmp/proj-a")
    assert :ok = Catalog.remember("sess-b", "/tmp/proj-b")

    assert {:ok, [%{id: "sess-b", cwd: "/tmp/proj-b"}, %{id: "sess-a", cwd: "/tmp/proj-a"}]} =
             Catalog.entries()

    assert {:ok, %{id: "sess-b", cwd: "/tmp/proj-b", last_used_at: at}} = Catalog.most_recent()
    assert {:ok, _at, 0} = DateTime.from_iso8601(at)
    assert {:ok, %{cwd: "/tmp/proj-a"}} = Catalog.lookup("sess-a")

    # Re-remembering an id moves it back to the front.
    assert :ok = Catalog.remember("sess-a", "/tmp/proj-a")
    assert {:ok, %{id: "sess-a"}} = Catalog.most_recent()

    assert :ok = Catalog.forget("sess-a")
    assert {:error, :not_found} = Catalog.lookup("sess-a")
    assert {:ok, %{id: "sess-b"}} = Catalog.most_recent()
  end

  test "prunes entries whose transcript no longer exists" do
    create_store!("/tmp/proj-a", "sess-a")
    create_store!("/tmp/proj-b", "sess-b")
    assert :ok = Catalog.remember("sess-a", "/tmp/proj-a")
    assert :ok = Catalog.remember("sess-b", "/tmp/proj-b")

    File.rm!(Store.path_for("/tmp/proj-b", "sess-b"))

    assert {:ok, [%{id: "sess-a"}]} = Catalog.entries()
    assert {:ok, %{id: "sess-a"}} = Catalog.most_recent()
    assert {:error, :not_found} = Catalog.lookup("sess-b")
  end

  test "a missing catalog file reads as empty" do
    assert {:ok, []} = Catalog.entries()
    assert {:error, :empty} = Catalog.most_recent()
    assert {:error, :not_found} = Catalog.lookup("sess-a")
  end

  test "a corrupt catalog returns tagged read errors and remember self-heals", %{path: path} do
    File.write!(path, "not json{")

    assert {:error, {:decode_failed, _reason}} = Catalog.entries()
    assert {:error, {:decode_failed, _reason}} = Catalog.most_recent()
    assert {:error, {:decode_failed, _reason}} = Catalog.forget("sess-a")

    create_store!("/tmp/proj-a", "sess-a")

    log =
      capture_log(fn ->
        assert :ok = Catalog.remember("sess-a", "/tmp/proj-a")
      end)

    assert log =~ "session catalog unreadable"
    assert {:ok, [%{id: "sess-a"}]} = Catalog.entries()
  end

  test "an unknown catalog version is a tagged error", %{path: path} do
    File.write!(path, ~s({"version": 99, "entries": []}))

    assert {:error, {:unsupported_catalog_version, 99}} = Catalog.entries()
  end

  test "invalid entry shapes are dropped instead of failing the catalog", %{path: path} do
    create_store!("/tmp/proj-a", "sess-a")

    File.write!(
      path,
      ~s({"version": 1, "entries": [{"id": "sess-a", "cwd": "/tmp/proj-a"}, {"id": 42}, "junk"]})
    )

    assert {:ok, [%{id: "sess-a", cwd: "/tmp/proj-a", last_used_at: _at}]} = Catalog.entries()
  end

  test "an uncreatable catalog directory is a tagged error", %{dir: dir} do
    blocker = Path.join(dir, "blocked")
    File.write!(blocker, "a regular file, not a directory")

    Application.put_env(
      :catalyst,
      :session_catalog_path,
      Path.join([blocker, "nested", "session_catalog.json"])
    )

    capture_log(fn ->
      assert {:error, {:mkdir_failed, _posix}} = Catalog.remember("sess-a", "/tmp/proj-a")
    end)
  end
end
