defmodule Catalyst.Flex.ProviderLoopFlexTest do
  use Catalyst.FlexCase, async: false

  @moduletag :flexibility

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Hooks, Message, Model}

  test "C3: API provider, custom loop, and live prompt compose with explicit loop sovereignty" do
    install_fixture!("flex_echo_provider")
    load_fixture!("flex_loop")

    previous_loop = with_agent_loop(Catalyst.Ext.FlexLoop)
    previous_prompt = write_system_prompt!("FLEX-SYS\nadditional prompt text")

    observer_owner = "flex_loop_sovereignty"
    test_pid = self()

    Hooks.on(fn event -> send(test_pid, {:custom_loop_observer, event}) end,
      owner: observer_owner
    )

    ExUnit.Callbacks.on_exit(fn -> Hooks.unregister(observer_owner) end)

    model = %Model{id: "flex-model", api: "flex-echo", provider: "flex-echo"}
    custom = run_headless_turn!("hello", model: model)

    assert assistant_text(custom.snapshot) =~ "[flex-loop] [flex-echo]"
    assert assistant_text(custom.snapshot) =~ "sys=FLEX-SYS"

    await_observers!(custom.id)
    refute_received {:custom_loop_observer, _event}

    direct =
      run_loop!(Catalyst.Ext.FlexLoop, "direct", %{
        provider: Catalyst.Ext.FlexEchoProvider,
        model: model,
        cwd: File.cwd!(),
        tools: :extensions,
        opts: []
      })

    assert [
             %Event.AgentStart{},
             %Event.MessageEnd{message: %Message.User{}},
             %Event.MessageEnd{message: %Message.Assistant{}},
             %Event.AgentEnd{}
           ] = direct.events

    Hooks.unregister(observer_owner)

    overridden =
      run_headless_turn!("session override",
        model: model,
        opts: [loop: Catalyst.Agent.Loop]
      )

    assert assistant_text(overridden.snapshot) =~ "[flex-echo]"
    refute assistant_text(overridden.snapshot) =~ "[flex-loop]"

    restore_app_env(:catalyst, :agent_loop, previous_loop)
    restore_file(Catalyst.SystemPrompt.path(), previous_prompt)
    remove_installed_fixture!("flex_echo_provider")
    unload_fixture!("flex_loop")

    baseline_model = %Model{id: "faux", api: "faux", provider: "faux"}

    baseline =
      run_headless_turn!("baseline",
        provider: Catalyst.LLM.Faux,
        model: baseline_model,
        opts: [script: [{:text, "BASELINE-LOOP"}]]
      )

    assert assistant_text(baseline.snapshot) == "BASELINE-LOOP"
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
