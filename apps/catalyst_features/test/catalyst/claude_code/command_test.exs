defmodule Catalyst.ClaudeCode.CommandTest do
  use ExUnit.Case, async: false

  alias Catalyst.ClaudeCode.Command

  test "keeps Claude's default prompt when Catalyst has no explicit override" do
    config = config(nil)
    assert {:ok, command} = Command.build("hello", config, nil)

    refute "--system-prompt-file" in command.args
    refute "--append-system-prompt-file" in command.args
    assert "--safe-mode" in command.args
    assert "--dangerously-skip-permissions" in command.args
    assert command.prompt_dir == nil
  end

  test "writes an explicit replacement prompt to a private temporary file" do
    assert {:ok, command} = Command.build("hello", config("replacement"), "session-1")
    index = Enum.find_index(command.args, &(&1 == "--system-prompt-file"))
    path = Enum.at(command.args, index + 1)

    assert File.read!(path) == "replacement"

    assert match?(
             {:ok, %File.Stat{mode: mode}} when Bitwise.band(mode, 0o777) == 0o600,
             File.stat(path)
           )

    assert Enum.chunk_every(command.args, 2, 1, :discard)
           |> Enum.any?(&(&1 == ["--resume", "session-1"]))

    assert :ok = Command.cleanup(command)
    refute File.exists?(path)
  end

  test "does not leave a prompt file when a later command option is invalid" do
    before = prompt_directories()

    config = %{
      config("sensitive replacement")
      | opts: [
          claude_executable: System.find_executable("elixir"),
          claude_permission_mode: :invalid
        ]
    }

    assert {:error, {:invalid_claude_permission_mode, :invalid}} =
             Command.build("hello", config, nil)

    assert prompt_directories() == before
  end

  defp config(prompt_override) do
    %{
      prompt_override: prompt_override,
      opts: [claude_executable: System.find_executable("elixir")]
    }
  end

  defp prompt_directories do
    System.tmp_dir!()
    |> Path.join("catalyst-claude-*")
    |> Path.wildcard()
    |> MapSet.new()
  end
end
