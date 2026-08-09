defmodule Catalyst.Tools.Shell.PtyTest do
  use ExUnit.Case, async: true

  alias Catalyst.Tools.Shell.{Buffer, Pty}

  doctest Catalyst.Tools.Shell.Pty
  doctest Catalyst.Tools.Shell.Buffer

  describe "Pty.default_shell/1" do
    test "prefers an executable $SHELL" do
      assert Pty.default_shell(fn "SHELL" -> "/bin/sh" end) == "/bin/sh"
    end

    test "falls back past an unset or missing $SHELL" do
      assert Pty.default_shell(fn "SHELL" -> nil end) in ["/bin/zsh", "/bin/sh"]
      assert Pty.default_shell(fn "SHELL" -> "/nonexistent/shell" end) in ["/bin/zsh", "/bin/sh"]
    end
  end

  describe "Buffer" do
    test "keeps unread output across takes in FIFO order" do
      buffer = Buffer.new(100) |> Buffer.push("one ") |> Buffer.push("two")

      {first, rest} = Buffer.take(buffer, 4)
      {second, rest} = Buffer.take(rest, 100)

      assert first == "one "
      assert second == "two"
      assert Buffer.size(rest) == 0
    end

    test "evicts oldest bytes past the cap and counts the drop" do
      buffer = Buffer.new(6) |> Buffer.push("aaa") |> Buffer.push("bbb") |> Buffer.push("cc")

      assert Buffer.size(buffer) <= 6
      assert Buffer.dropped(buffer) == 3
      {out, _rest} = Buffer.take(buffer, 100)
      assert out == "bbbcc"
    end

    test "a single oversized chunk keeps its tail" do
      buffer = Buffer.new(4) |> Buffer.push("abcdefgh")

      assert Buffer.dropped(buffer) == 4
      {out, _rest} = Buffer.take(buffer, 100)
      assert out == "efgh"
    end

    test "take never splits a multibyte character across reads" do
      buffer = Buffer.new(100) |> Buffer.push("a") |> Buffer.push("é")

      {first, rest} = Buffer.take(buffer, 2)
      {second, _rest} = Buffer.take(rest, 100)

      assert first == "a"
      assert second == "é"
    end

    test "take resets the dropped counter" do
      buffer = Buffer.new(2) |> Buffer.push("abc")
      {_out, rest} = Buffer.take(buffer, 100)

      assert Buffer.dropped(rest) == 0
    end
  end
end
