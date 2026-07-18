defmodule CatalystWeb.ShellLive.CommandsTest do
  use ExUnit.Case, async: true

  alias CatalystWeb.ShellLive.Commands

  describe "parse/1" do
    test "parses command names with optional arguments" do
      assert Commands.parse("/cd") == {:ok, "cd", ""}
      assert Commands.parse("/cd child directory") == {:ok, "cd", "child directory"}
      assert Commands.parse("/ping_test   hello") == {:ok, "ping_test", "hello"}
    end

    test "leaves ordinary slash-prefixed text for the model" do
      assert Commands.parse("/etc/passwd contains users") == :error
      assert Commands.parse("/MixedCase") == :error
      assert Commands.parse("not a command") == :error
    end
  end
end
