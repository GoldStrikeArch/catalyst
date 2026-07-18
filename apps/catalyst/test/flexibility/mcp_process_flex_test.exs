defmodule Catalyst.Flex.McpProcessFlexTest do
  use Catalyst.FlexCase, async: false

  @moduletag :flexibility

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message, Model}

  test "C4: process-backed tool, result hook, and ordered observer compose and revert" do
    previous_observer = with_app_env(:catalyst, :flex_observer_pid, self())
    install_fixture!("mcp_stub")
    install_fixture!("hook_pack")

    [process] = Catalyst.Extensions.Processes.list("mcp_stub")
    :ok = apply(Catalyst.Ext.McpStubState, :put, ["answer", "99"])

    run =
      run_headless_turn!("lookup",
        provider: Catalyst.LLM.Faux,
        model: %Model{id: "faux", api: "faux", provider: "faux"},
        opts: [
          script: [
            {:tool, "mcp_lookup", %{"key" => "answer"}},
            {:text, "lookup complete"}
          ]
        ]
      )

    assert tool_text(run.snapshot, "mcp_lookup") == "MCP answer=99 [hooked]"
    assert_received {:flex_hook_effect, {:before_tool_call, "mcp_lookup"}}
    assert_received {:flex_hook_effect, {:after_tool_call, "mcp_lookup"}}

    await_observers!(run.id)
    observer_events = drain_observer_events([])

    assert [%Event.AgentStart{} | _rest] = observer_events
    assert %Event.AgentEnd{} = List.last(observer_events)

    process_ref = Process.monitor(process)
    remove_installed_fixture!("hook_pack")
    remove_installed_fixture!("mcp_stub")

    assert_receive {:DOWN, ^process_ref, :process, ^process, _reason}, 1_000
    assert Catalyst.Extensions.fetch("mcp_lookup") == :error
    assert Catalyst.Extensions.Processes.list("mcp_stub") == []

    restore_app_env(:catalyst, :flex_observer_pid, previous_observer)
  end

  defp tool_text(snapshot, name) do
    snapshot.messages
    |> Enum.find(fn
      %Message.ToolResult{tool_name: ^name} -> true
      _message -> false
    end)
    |> then(&Content.text_of(&1.content))
  end

  defp drain_observer_events(acc) do
    receive do
      {:flex_hook_observer, event} -> drain_observer_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
