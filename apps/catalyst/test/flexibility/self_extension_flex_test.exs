defmodule Catalyst.Flex.SelfExtensionFlexTest do
  use Catalyst.FlexCase, async: false

  @moduletag :flexibility

  alias Catalyst.{Content, Extensions, Message, Model}
  alias Catalyst.Extensions.Versioning

  @tag :git
  test "C5: one run installs and invokes another extension, then LIFO rollback removes both" do
    case Versioning.available?() do
      false ->
        :ok

      true ->
        install_fixture!("installer_tool")

        ExUnit.Callbacks.on_exit(fn ->
          remove_installed_fixture!("flex_installed_child")
        end)

        run =
          run_headless_turn!("extend again",
            provider: Catalyst.LLM.Faux,
            model: %Model{id: "faux", api: "faux", provider: "faux"},
            opts: [
              script: [
                {:tool, "install_more", %{}},
                {:tool, "flex_child", %{}},
                {:text, "self-extension complete"}
              ]
            ]
          )

        assert tool_text(run.snapshot, "install_more") == "INSTALLED-MORE"
        assert tool_text(run.snapshot, "flex_child") == "FLEX-CHILD-RAN"

        await_observers!(run.id)
        assert apply(Catalyst.Ext.InstallerCounter, :count, []) >= 2

        {log, 0} = System.cmd("git", ["log", "--format=%s"], cd: Extensions.dir())
        assert log =~ "flex fixture installer_tool"
        assert log =~ "flex child flex_installed_child"

        assert :ok = Versioning.rollback(Extensions.dir())
        assert {:ok, %{failed: []}} = Extensions.load_all()
        refute File.exists?(Path.join(Extensions.dir(), "flex_installed_child.ex"))
        assert Extensions.fetch("flex_child") == :error

        assert :ok = Versioning.rollback(Extensions.dir())
        assert {:ok, %{failed: []}} = Extensions.load_all()
        refute File.exists?(Path.join(Extensions.dir(), "installer_tool.ex"))
        assert Extensions.fetch("install_more") == :error

        baseline =
          run_headless_turn!("baseline",
            provider: Catalyst.LLM.Faux,
            model: %Model{id: "faux", api: "faux", provider: "faux"},
            opts: [script: [{:text, "BASELINE-AFTER-ROLLBACK"}]]
          )

        assert assistant_text(baseline.snapshot) == "BASELINE-AFTER-ROLLBACK"
    end
  end

  defp tool_text(snapshot, name) do
    snapshot.messages
    |> Enum.find(fn
      %Message.ToolResult{tool_name: ^name} -> true
      _message -> false
    end)
    |> then(&Content.text_of(&1.content))
  end

  defp assistant_text(snapshot) do
    snapshot.messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message.Assistant{content: content} -> Content.text_of(content)
      _message -> false
    end)
  end
end
