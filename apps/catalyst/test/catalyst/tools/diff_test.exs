defmodule Catalyst.Tools.DiffTest do
  use ExUnit.Case, async: true

  alias Catalyst.Tools.Diff

  test "rendered diff scrubs invalid UTF-8" do
    rendered = Diff.rendered("old\n", <<"new", 255, "\n">>)

    assert String.valid?(rendered)
    assert rendered =~ "-old"
    assert rendered =~ "+new�"
  end

  test "identical strings produce an empty diff" do
    assert Diff.unified("a\nb\nc", "a\nb\nc") == ""
  end

  test "a change produces a hunk with -/+ lines and surrounding context" do
    old = Enum.join(~w(a b c d e f g h), "\n")
    new = Enum.join(~w(a b c D e f g h), "\n")

    diff = Diff.unified(old, new)

    assert diff =~ ~r/^@@ -1,7 \+1,7 @@$/m
    assert diff =~ ~r/^-d$/m
    assert diff =~ ~r/^\+D$/m
    # 3 lines of context on each side, nothing further away.
    assert diff =~ ~r/^ c$/m
    assert diff =~ ~r/^ g$/m
    refute diff =~ ~r/^ h$/m
  end

  test "distant changes produce separate hunks" do
    old = Enum.map_join(1..30, "\n", &"line #{&1}")
    new = old |> String.replace("line 3", "LINE 3") |> String.replace("line 27", "LINE 27")

    diff = Diff.unified(old, new)

    assert length(String.split(diff, "@@ -")) == 3
    assert diff =~ "-line 3\n"
    assert diff =~ "+LINE 27"
  end

  test "insertions and deletions count lines correctly in the hunk header" do
    old = "a\nb\nc"
    new = "a\nb\nx\ny\nc"

    diff = Diff.unified(old, new)
    assert diff =~ "@@ -1,3 +1,5 @@"
    assert diff =~ "+x\n+y"
  end

  test "the edit tool surfaces the diff in content and details" do
    tmp = Path.join(System.tmp_dir!(), "diff_edit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    path = Path.join(tmp, "sample.txt")
    File.write!(path, "hello\nworld\n")

    res =
      Catalyst.Tools.Edit.execute(
        %{"path" => path, "edits" => [%{"oldText" => "world", "newText" => "elixir"}]},
        %{cwd: tmp, call_id: "t", report: fn _ -> :ok end}
      )

    assert res.details.diff =~ ~r/^-world$/m
    assert res.details.diff =~ ~r/^\+elixir$/m
    assert Catalyst.Content.text_of(res.content) =~ "+elixir"
  end

  test "very large inputs suppress the diff with a size summary" do
    old = Enum.map_join(1..3000, "\n", &"old #{&1}")
    new = Enum.map_join(1..3000, "\n", &"new #{&1}")

    assert Diff.unified(old, new) =~ "diff suppressed: file too large — 3000 -> 3000 lines"
    # Equal contents still short-circuit to "" regardless of size.
    assert Diff.unified(old, old) == ""
  end

  test "max_lines caps the output with a truncation note" do
    old = Enum.map_join(1..100, "\n", &"old #{&1}")
    new = Enum.map_join(1..100, "\n", &"new #{&1}")

    diff = Diff.unified(old, new, max_lines: 10)

    assert diff =~ "(diff truncated)"
    assert diff |> String.split("\n") |> length() <= 12
  end
end
