defmodule Catalyst.Tools.TruncateTest do
  use ExUnit.Case, async: true
  alias Catalyst.Tools.Truncate

  test "head keeps the first N lines" do
    content = Enum.map_join(1..100, "\n", &"line #{&1}")
    {out, info} = Truncate.head(content, max_lines: 10)
    assert info.truncated
    assert info.truncated_by == :lines
    assert info.total_lines == 100
    assert info.output_lines == 10
    assert String.starts_with?(out, "line 1\n")
    assert String.ends_with?(out, "line 10")
  end

  test "tail keeps the last N lines" do
    content = Enum.map_join(1..100, "\n", &"line #{&1}")
    {out, info} = Truncate.tail(content, max_lines: 5)
    assert info.truncated
    assert String.ends_with?(out, "line 100")
    assert String.starts_with?(out, "line 96\n")
  end

  test "no truncation when within budget" do
    {out, info} = Truncate.head("a\nb\nc")
    refute info.truncated
    assert info.truncated_by == nil
    assert out == "a\nb\nc"
  end

  test "a single trailing newline is not counted as an extra line" do
    {out, info} = Truncate.head("a\nb\nc\n")
    refute info.truncated
    assert info.total_lines == 3
    assert info.output_lines == 3
    assert out == "a\nb\nc\n"
  end

  test "exactly max_lines lines plus a trailing newline is not truncated" do
    content = Enum.map_join(1..10, "\n", &"line #{&1}") <> "\n"
    {out, info} = Truncate.head(content, max_lines: 10)
    refute info.truncated
    assert out == content
  end

  test "tail on newline-terminated content keeps whole real lines" do
    content = Enum.map_join(1..100, "\n", &"line #{&1}") <> "\n"
    {out, info} = Truncate.tail(content, max_lines: 5)
    assert info.truncated
    assert info.total_lines == 100
    assert String.starts_with?(out, "line 96\n")
    assert String.ends_with?(out, "line 100")
  end

  test "listing appends a limit marker only when limited" do
    {text, info} = Truncate.listing("a\nb", limited?: true, limit: 2, total: 5, noun: "entries")
    assert text =~ "[showing first 2 of 5 entries]"
    refute info.truncated

    {text, _info} =
      Truncate.listing("a\nb", limited?: true, limit: 2, total: :unknown, noun: "results")

    assert text =~ "[showing first 2 results; more exist]"

    {text, _info} = Truncate.listing("a\nb", limited?: false, limit: 2, total: 5, noun: "entries")
    assert text == "a\nb"
  end

  test "byte budget clamps and keeps valid UTF-8" do
    content = String.duplicate("héllo\n", 100)
    {out, info} = Truncate.head(content, max_lines: 1000, max_bytes: 50)
    assert info.truncated
    assert info.truncated_by == :bytes
    assert byte_size(out) <= 50
    assert String.valid?(out)
  end

  test "scrub_utf8 replaces invalid bytes and passes valid input through" do
    assert Truncate.scrub_utf8("plain text") == "plain text"
    scrubbed = Truncate.scrub_utf8(<<"a", 255, 254, "b">>)
    assert String.valid?(scrubbed)
    assert scrubbed == "a��b"
  end

  test "notice appends/prepends a truncation marker only when truncated" do
    content = Enum.map_join(1..100, "\n", &"line #{&1}")

    {out, info} = Truncate.head(content, max_lines: 10)

    assert Truncate.notice(out, info, :head) =~
             "[output truncated: showing first 10 of 100 lines]"

    {out, info} = Truncate.tail(content, max_lines: 10)
    assert Truncate.notice(out, info, :tail) =~ "[output truncated: showing last 10 of 100 lines]"

    {out, info} = Truncate.head("a\nb")
    assert Truncate.notice(out, info, :head) == "a\nb"
  end
end
