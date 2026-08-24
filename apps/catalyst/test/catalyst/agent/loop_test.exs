defmodule Catalyst.Agent.LoopTest do
  use ExUnit.Case, async: false

  alias Catalyst.Agent.Loop
  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message, Model}
  alias Catalyst.Tools.Registry

  defmodule FailingProvider do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(_model, _context, _opts, _sink), do: {:error, :boom}
  end

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
    assert_guard_before_each_turn(events, 3)
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

  test "the guard runs before initial and resumed session requests", %{tmp: tmp} do
    config = %{
      provider: Catalyst.LLM.Faux,
      model: %Model{id: "faux", api: "faux", provider: "faux"},
      cwd: tmp,
      tools: Registry.default_tools(),
      opts: [script: [{:text, "initial"}, {:text, "resumed"}]]
    }

    initial_events =
      run_events(
        [Message.user("new")],
        %{system_prompt: nil, messages: []},
        config
      )

    resumed_context = %{
      system_prompt: nil,
      messages: [Message.user("old"), assistant("old answer")]
    }

    resumed_events = run_events([Message.user("continue")], resumed_context, config)

    assert_guard_before_each_turn(initial_events, 1)
    assert_guard_before_each_turn(resumed_events, 1)
  end

  test "a steer arriving during the final toolless turn runs another turn", %{tmp: tmp} do
    # Drain calls: 0 = loop start (empty), 1 = the re-check after the final
    # turn (delivers the steer), later = empty.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    get_steering = fn ->
      case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
        1 -> [Message.user("actually, one more thing")]
        _ -> []
      end
    end

    config = %{
      provider: Catalyst.LLM.Faux,
      model: %Model{id: "faux", api: "faux", provider: "faux"},
      cwd: tmp,
      tools: Registry.default_tools(),
      opts: [script: [{:text, "first"}, {:text, "after steer"}]],
      get_steering: get_steering
    }

    {:ok, agent} = Agent.start_link(fn -> [] end)
    emit = fn event -> Agent.update(agent, &[event | &1]) end

    {:ok, msgs, _ctx} =
      Loop.run([Message.user("go")], %{system_prompt: nil, messages: []}, config, emit)

    events = agent |> Agent.get(&Enum.reverse/1) |> tap(fn _events -> Agent.stop(agent) end)

    # The steer was injected and answered in the SAME run, not left queued.
    assert roles(msgs) == [:user, :assistant, :user, :assistant]
    assert Content.text_of(List.last(msgs).content) == "after steer"
    assert_guard_before_each_turn(events, 2)
  end

  test "the guard runs before a queued follow-up request", %{tmp: tmp} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    get_follow_up = fn ->
      case Agent.get_and_update(counter, fn count -> {count, count + 1} end) do
        0 -> [Message.user("queued follow-up")]
        _later -> []
      end
    end

    config = %{
      provider: Catalyst.LLM.Faux,
      model: %Model{id: "faux", api: "faux", provider: "faux"},
      cwd: tmp,
      tools: Registry.default_tools(),
      opts: [script: [{:text, "first"}, {:text, "follow-up answer"}]],
      get_follow_up: get_follow_up
    }

    events = run_events([Message.user("go")], %{system_prompt: nil, messages: []}, config)

    assert_guard_before_each_turn(events, 2)
    Agent.stop(counter)
  end

  test "a provider error ends the run without draining follow-ups", %{tmp: tmp} do
    parent = self()

    get_follow_up = fn ->
      send(parent, :follow_up_drained)
      [Message.user("queued follow-up")]
    end

    config = %{
      provider: FailingProvider,
      model: %Model{id: "faux", api: "faux", provider: "faux"},
      cwd: tmp,
      tools: Registry.default_tools(),
      opts: [],
      get_follow_up: get_follow_up
    }

    {:ok, agent} = Agent.start_link(fn -> [] end)
    emit = fn ev -> Agent.update(agent, &[ev | &1]) end

    {:ok, msgs, _ctx} =
      Loop.run([Message.user("go")], %{system_prompt: nil, messages: []}, config, emit)

    events = Agent.get(agent, & &1) |> Enum.reverse()
    Agent.stop(agent)

    # One failed assistant turn, then a hard stop: the queued follow-up was
    # never drained into another doomed provider call.
    assert roles(msgs) == [:user, :assistant]
    assert List.last(msgs).stop_reason == :error
    refute_received :follow_up_drained

    assert Enum.any?(events, &match?(%Event.TurnEnd{}, &1))
    assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
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

  defp run_events(prompts, context, config) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    emit = fn event -> Agent.update(agent, &[event | &1]) end

    assert {:ok, _messages, _context} = Loop.run(prompts, context, config, emit)

    events = Agent.get(agent, &Enum.reverse/1)
    Agent.stop(agent)
    events
  end

  defp assert_guard_before_each_turn(events, expected_count) do
    statuses = event_indexes(events, Event.ContextStatus)
    turns = event_indexes(events, Event.TurnStart)

    assert length(statuses) == expected_count
    assert length(turns) == expected_count
    assert Enum.zip(statuses, turns) |> Enum.all?(fn {status, turn} -> status < turn end)
  end

  defp event_indexes(events, module) do
    events
    |> Enum.with_index()
    |> Enum.filter(fn {event, _index} -> event.__struct__ == module end)
    |> Enum.map(&elem(&1, 1))
  end

  defp assistant(text) do
    %Message.Assistant{content: Content.text(text), stop_reason: :stop}
  end
end
