defmodule CatalystWeb.ShellLive.ChatInputTest do
  use ExUnit.Case, async: true

  alias CatalystWeb.ShellLive.ChatInput

  describe "expand_refs/2" do
    test "returns text unchanged when no files were selected" do
      assert ChatInput.expand_refs(%{}, "inspect @file.ex") == "inspect @file.ex"
    end

    test "expands longer labels before labels that are their prefix" do
      refs = %{
        "@app" => "apps/catalyst",
        "@app/server.ex" => "apps/catalyst/lib/server.ex"
      }

      assert ChatInput.expand_refs(refs, "compare @app/server.ex with @app") ==
               "compare apps/catalyst/lib/server.ex with apps/catalyst"
    end
  end
end
