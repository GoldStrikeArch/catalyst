defmodule CatalystWeb.FileSearchTest do
  # async: false — shells out to the real fd binary.
  use ExUnit.Case, async: false

  alias CatalystWeb.FileSearch

  defp tmp_tree!(files) do
    root = Path.join(System.tmp_dir!(), "catalyst_fs_#{System.unique_integer([:positive])}")

    Enum.each(files, fn rel ->
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# #{rel}\n")
    end)

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  test "labels are @parent/name; same-named files extend upward until distinct" do
    root = tmp_tree!(["apps/x/session/server.ex", "qwe/server.ex", "other/thing.ex"])

    results = FileSearch.search(root, "server")
    labels = results |> Enum.map(& &1.label) |> Enum.sort()

    assert labels == ["@qwe/server.ex", "@session/server.ex"]

    by_label = Map.new(results, &{&1.label, &1.path})
    assert by_label["@session/server.ex"] == "apps/x/session/server.ex"
    assert by_label["@qwe/server.ex"] == "qwe/server.ex"
  end

  test "collisions at parent depth grow segment by segment; unique files stay short" do
    root =
      tmp_tree!([
        "a/lib/session/server.ex",
        "b/lib/session/server.ex",
        "other/thing.ex",
        "top.ex"
      ])

    labels = root |> FileSearch.search("") |> Enum.map(& &1.label) |> Enum.sort()

    assert "@a/lib/session/server.ex" in labels
    assert "@b/lib/session/server.ex" in labels
    # Unique files are not lengthened by the others' collision.
    assert "@other/thing.ex" in labels
    assert "@top.ex" in labels
  end

  test "queries can use the label shape (dir/name) thanks to --full-path" do
    root = tmp_tree!(["apps/x/session/server.ex", "qwe/server.ex"])

    assert [%{path: "apps/x/session/server.ex"}] = FileSearch.search(root, "session/serv")
  end

  test "no matches and broken patterns degrade to an empty list" do
    root = tmp_tree!(["a.ex"])

    assert FileSearch.search(root, "zzz_nothing_zzz") == []
    # An invalid regex must not raise out of the search.
    assert FileSearch.search(root, "[unclosed") == []
  end
end
