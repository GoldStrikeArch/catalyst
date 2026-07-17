defmodule Catalyst.SystemPromptTest do
  # async: false — the override file path is shared global state.
  use ExUnit.Case, async: false

  alias Catalyst.SystemPrompt

  setup do
    File.rm(SystemPrompt.path())
    on_exit(fn -> File.rm(SystemPrompt.path()) end)
    :ok
  end

  test "falls back to the built-in default (which advertises its own override)" do
    assert SystemPrompt.get() == SystemPrompt.default()
    assert SystemPrompt.get() =~ "system_prompt.md"
  end

  test "a non-blank override file replaces the prompt" do
    File.write!(SystemPrompt.path(), "You are a pirate. Answer in rhyme.")
    assert SystemPrompt.get() == "You are a pirate. Answer in rhyme."
  end

  test "a blank override file is ignored" do
    File.write!(SystemPrompt.path(), "   \n\n")
    assert SystemPrompt.get() == SystemPrompt.default()
  end

  test "deleting the override restores the default (the revert path)" do
    File.write!(SystemPrompt.path(), "custom")
    assert SystemPrompt.get() == "custom"

    File.rm!(SystemPrompt.path())
    assert SystemPrompt.get() == SystemPrompt.default()
  end
end
