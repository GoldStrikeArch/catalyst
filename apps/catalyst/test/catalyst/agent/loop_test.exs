defmodule Catalyst.Agent.LoopTest do
  use ExUnit.Case, async: true

  alias Catalyst.Agent.Loop
  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message, Model}
  alias Catalyst.Tools.Registry

  setup do
    tmp = Path.join(System.tmp_dir!(), "catalyst_loop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp run(script, prompt, tmp) do
    model = %Model{id: "faux", api: "faux", provider: "faux"}

    config = %{
      provider: Catalyst.LLM.Faux,
      model: model,
      cwd: tmp,
      tools: Registry.default_tools(),
      opts: [script: script]
    }

    {:ok, agent} = Agent.start_link(fn -> [] end)
    emit = fn ev -> Agent.update(agent, &[ev | &1]) end

    {:ok, msgs, _ctx} =
      Loop.run([Message.user(prompt)], %{system_prompt: nil, messages: []}, config, emit)

    events = Agent.get(agent, & &1) |> Enum.reverse()
    Agent.stop(agent)
    {msgs, events}
  end

  defp roles(msgs) do
    Enum.map(msgs, fn
      %Message.User{} -> :user
      %Message.Assistant{} -> :assistant
      %Message.ToolResult{} -> :tool_result
    end)
  end

  test "runs tools then a final text turn", %{tmp: tmp} do
    script = [
      {:tool, "write", %{"path" => "a.txt", "content" => "hi there"}},
      {:tool, "read", %{"path" => "a.txt"}},
      {:text, "all done"}
    ]

    {msgs, events} = run(script, "do it", tmp)

    assert roles(msgs) == [:user, :assistant, :tool_result, :assistant, :tool_result, :assistant]
    assert List.last(msgs).stop_reason == :stop
    assert Content.text_of(List.last(msgs).content) == "all done"

    read_result = Enum.find(msgs, &match?(%Message.ToolResult{tool_name: "read"}, &1))
    assert Content.text_of(read_result.content) =~ "hi there"

    assert Enum.any?(events, &match?(%Event.AgentStart{}, &1))
    assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
    assert Enum.count(events, &match?(%Event.ToolExecutionEnd{}, &1)) == 2
  end

  test "a failing tool becomes an error result and the loop continues", %{tmp: tmp} do
    script = [
      {:tool, "read", %{"path" => "missing.txt"}},
      {:text, "recovered"}
    ]

    {msgs, _events} = run(script, "go", tmp)

    tool_result = Enum.find(msgs, &match?(%Message.ToolResult{}, &1))
    assert tool_result.is_error

    assert Content.text_of(tool_result.content) =~ "no such file" or
             Content.text_of(tool_result.content) =~ "missing.txt"

    assert Content.text_of(List.last(msgs).content) == "recovered"
  end

  test "parallel read-only tools all run", %{tmp: tmp} do
    File.write!(Path.join(tmp, "x.txt"), "needle\n")

    script = [
      {:tools, [{"grep", %{"pattern" => "needle"}}, {"find", %{"pattern" => "*.txt"}}]},
      {:text, "done"}
    ]

    {msgs, _events} = run(script, "search", tmp)

    tool_results = Enum.filter(msgs, &match?(%Message.ToolResult{}, &1))
    assert length(tool_results) == 2
    assert Enum.map(tool_results, & &1.tool_name) |> Enum.sort() == ["find", "grep"]
  end
end
