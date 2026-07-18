defmodule Catalyst.Flex.ShadowFlexTest do
  use Catalyst.FlexCase, async: false

  @moduletag :flexibility

  alias Catalyst.{Content, Extensions, Message, Model}
  alias Catalyst.Session.Server

  defp model, do: %Model{id: "faux", api: "faux", provider: "faux"}

  test "C1: a runtime tool-name shadow affects a real turn and cleanly reverts", %{
    flex_home: home
  } do
    File.write!(Path.join(home, "baseline.txt"), "known")
    install_fixture!("shadow_ls_tool")

    shadowed =
      run_headless_turn!("list",
        provider: Catalyst.LLM.Faux,
        model: model(),
        opts: [
          script: [{:tool, "ls", %{}}, {:text, "shadow complete"}]
        ]
      )

    assert tool_text(shadowed.snapshot, "ls") == "SHADOWED-LS"
    assert Extensions.fetch("ls") == {:ok, Catalyst.Ext.ShadowLsTool}

    remove_installed_fixture!("shadow_ls_tool")
    assert Extensions.fetch("ls") == {:ok, Catalyst.Tools.Ls}

    restored =
      run_headless_turn!("list",
        provider: Catalyst.LLM.Faux,
        model: model(),
        opts: [
          script: [{:tool, "ls", %{}}, {:text, "baseline complete"}]
        ]
      )

    assert tool_text(restored.snapshot, "ls") =~ "baseline.txt"
    refute tool_text(restored.snapshot, "ls") =~ "SHADOWED-LS"
  end

  test "C2: application-module shadows restore code but not already-folded state", %{
    flex_home: home
  } do
    File.write!(Path.join(home, "restored.txt"), "known")

    original = %{
      ls: object_code_hash(Catalyst.Tools.Ls),
      reducer: object_code_hash(Catalyst.Session.Reducer)
    }

    session =
      start_session!(
        provider: Catalyst.LLM.Faux,
        model: model(),
        opts: [script: [{:text, "baseline turn"}]]
      )

    first = run_session_turn!(session, "first")
    assert assistant_texts(first.snapshot) == ["baseline turn"]

    load_fixture!("shadow_core_module")
    load_fixture!("shadow_reducer")

    :ok =
      Server.configure(session.pid,
        opts: [
          script: [
            {:text, "unused"},
            {:tool, "ls", %{}},
            {:text, "shadow final"}
          ]
        ]
      )

    second = run_session_turn!(session, "second")
    assert tool_text(second.snapshot, "ls") == "CORE-SHADOW-LS"
    assert Enum.any?(assistant_texts(second.snapshot), &String.contains?(&1, "[shadow-reducer]"))

    unload_fixture!("shadow_reducer")
    unload_fixture!("shadow_core_module")

    assert object_code_hash(Catalyst.Tools.Ls) == original.ls
    assert object_code_hash(Catalyst.Session.Reducer) == original.reducer

    persisted_in_memory = Server.state(session.pid)

    assert Enum.any?(
             assistant_texts(persisted_in_memory),
             &String.contains?(&1, "[shadow-reducer]")
           )

    Server.reset(session.pid)
    _ = :sys.get_state(session.pid)
    assert Server.state(session.pid).messages == []

    :ok =
      Server.configure(session.pid,
        opts: [script: [{:tool, "ls", %{}}, {:text, "restored final"}]]
      )

    third = run_session_turn!(session, "third")
    assert tool_text(third.snapshot, "ls") =~ "restored.txt"
    refute Enum.any?(assistant_texts(third.snapshot), &String.contains?(&1, "[shadow-reducer]"))

    stop_session!(session.id, session.pid)
  end

  defp tool_text(snapshot, name) do
    snapshot.messages
    |> Enum.find(fn
      %Message.ToolResult{tool_name: ^name} -> true
      _message -> false
    end)
    |> then(&Content.text_of(&1.content))
  end

  defp assistant_texts(snapshot) do
    for %Message.Assistant{content: content} <- snapshot.messages, do: Content.text_of(content)
  end

  defp object_code_hash(module) do
    {^module, binary, _path} = :code.get_object_code(module)
    :crypto.hash(:sha256, binary)
  end
end
