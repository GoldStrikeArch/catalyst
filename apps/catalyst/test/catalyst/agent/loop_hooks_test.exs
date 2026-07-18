defmodule Catalyst.Agent.LoopHooksTest do
  # async: false — registers real loop hook points. Every behavior-changing hook
  # is guarded by THIS test's unique cwd, so it is a no-op for any other test
  # whose loop runs concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Catalyst.Agent.{Event, Loop}
  alias Catalyst.{Content, Hooks, Message, Model}
  alias Catalyst.Tools.Registry

  defmodule RecordingProvider do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(model, context, opts, _sink) do
      send(Keyword.fetch!(opts, :record_to), {:llm_messages, context.messages})

      {:ok,
       %Message.Assistant{
         content: Content.text("ok"),
         model: model && model.id,
         stop_reason: :stop,
         timestamp: Message.now()
       }}
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "catalyst_loophooks_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    owner = "loophooks_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Hooks.unregister(owner)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, owner: owner}
  end

  defp run(script, prompt, tmp, opts \\ []) do
    provider = Keyword.get(opts, :provider, Catalyst.LLM.Faux)
    provider_opts = Keyword.get(opts, :opts, script: script)

    config = %{
      provider: provider,
      model: %Model{id: "faux", api: "faux", provider: "faux"},
      cwd: tmp,
      tools: Registry.default_tools(),
      opts: provider_opts
    }

    {:ok, agent} = Agent.start_link(fn -> [] end)
    emit = fn ev -> Agent.update(agent, &[ev | &1]) end

    {:ok, msgs, _ctx} =
      Loop.run([Message.user(prompt)], %{system_prompt: nil, messages: []}, config, emit)

    events = Agent.get(agent, & &1) |> Enum.reverse()
    Agent.stop(agent)
    {msgs, events}
  end

  test "before_tool_call can block a tool (it never executes)", %{tmp: tmp, owner: owner} do
    Hooks.register(
      :before_tool_call,
      fn ctx ->
        if ctx.cwd == tmp and ctx.name == "write", do: {:block, "denied by test"}, else: :cont
      end,
      owner: owner
    )

    script = [
      {:tool, "write", %{"path" => "a.txt", "content" => "hi"}},
      {:text, "done"}
    ]

    {msgs, _events} = run(script, "go", tmp)

    write_result = Enum.find(msgs, &match?(%Message.ToolResult{tool_name: "write"}, &1))
    assert write_result.is_error
    assert Content.text_of(write_result.content) == "denied by test"
    # The tool never ran, so the file was not created.
    refute File.exists?(Path.join(tmp, "a.txt"))
  end

  test "before_tool_call safely formats a non-string block reason", %{tmp: tmp, owner: owner} do
    Hooks.register(
      :before_tool_call,
      fn ctx ->
        case ctx.cwd do
          ^tmp -> {:block, %{reason: :denied}}
          _other -> :cont
        end
      end,
      owner: owner
    )

    {msgs, _events} =
      run([{:tool, "write", %{"path" => "blocked.txt", "content" => "no"}}], "go", tmp)

    result = Enum.find(msgs, &match?(%Message.ToolResult{tool_name: "write"}, &1))
    assert result.is_error
    assert Content.text_of(result.content) == "%{reason: :denied}"
    refute File.exists?(Path.join(tmp, "blocked.txt"))
  end

  test "after_tool_call can override a tool result", %{tmp: tmp, owner: owner} do
    File.write!(Path.join(tmp, "x.txt"), "original")

    Hooks.register(
      :after_tool_call,
      fn {_content, details, _err, term}, ctx ->
        if ctx.cwd == tmp and ctx.name == "read",
          do: {:ok, {Content.text("REWRITTEN"), details, false, term}},
          else: :cont
      end,
      owner: owner
    )

    {msgs, _events} = run([{:tool, "read", %{"path" => "x.txt"}}, {:text, "done"}], "go", tmp)

    read_result = Enum.find(msgs, &match?(%Message.ToolResult{tool_name: "read"}, &1))
    assert Content.text_of(read_result.content) == "REWRITTEN"
  end

  test "transform_context can drop messages from the LLM request", %{tmp: tmp, owner: owner} do
    Hooks.register(
      :transform_context,
      fn msgs, ctx -> if ctx.config.cwd == tmp, do: {:ok, []}, else: {:ok, msgs} end,
      owner: owner
    )

    run([], "hello", tmp, provider: RecordingProvider, opts: [record_to: self()])

    # Without the hook the provider would have seen the user prompt; the hook
    # dropped it.
    assert_receive {:llm_messages, []}
  end

  test "a crashing hook is logged and the run still completes", %{tmp: tmp, owner: owner} do
    Hooks.register(
      :before_tool_call,
      fn ctx -> if ctx.cwd == tmp, do: raise("boom"), else: :cont end,
      owner: owner
    )

    log =
      capture_log(fn ->
        {msgs, _events} =
          run(
            [{:tool, "write", %{"path" => "b.txt", "content" => "ok"}}, {:text, "done"}],
            "go",
            tmp
          )

        # The hook crashed and was skipped, so the tool ran normally.
        assert File.read!(Path.join(tmp, "b.txt")) == "ok"
        assert Content.text_of(List.last(msgs).content) == "done"
      end)

    assert log =~ "boom"
  end

  test "should_stop_after_turn forces the loop to stop", %{tmp: tmp, owner: owner} do
    Hooks.register(
      :should_stop_after_turn,
      fn ctx -> if ctx.cwd == tmp, do: true, else: :cont end,
      owner: owner
    )

    # Without the stop hook this would run tool -> tool -> text (3 turns); the
    # hook stops it right after the first tool turn.
    script = [
      {:tool, "write", %{"path" => "c.txt", "content" => "1"}},
      {:tool, "write", %{"path" => "d.txt", "content" => "2"}},
      {:text, "done"}
    ]

    {msgs, _events} = run(script, "go", tmp)

    # Stopped after the first tool batch: no second write, no final text turn.
    assert File.exists?(Path.join(tmp, "c.txt"))
    refute File.exists?(Path.join(tmp, "d.txt"))

    refute Enum.any?(msgs, fn m ->
             match?(%Message.Assistant{}, m) and Content.text_of(m.content) == "done"
           end)
  end

  test "a prepare-next-turn model change is guarded before the next request", %{
    tmp: tmp,
    owner: owner
  } do
    File.write!(Path.join(tmp, "model-change.txt"), "fixture")
    next_model = %Model{id: "faux-next", api: "faux", provider: "faux"}

    Hooks.register(
      :prepare_next_turn,
      fn {context, config}, ctx ->
        case ctx.cwd == tmp and config.model.id == "faux" do
          true -> {:ok, {context, Map.put(config, :model, next_model)}}
          false -> {:ok, {context, config}}
        end
      end,
      owner: owner
    )

    initial_model = %Model{id: "faux", api: "faux", provider: "faux"}

    config = %{
      provider: Catalyst.LLM.Faux,
      model: initial_model,
      active_model_identity: {"faux", "faux", "faux"},
      active_prompt: nil,
      cwd: tmp,
      tools: Registry.default_tools(),
      opts: [
        script: [
          {:tool, "read", %{"path" => "model-change.txt"}},
          {:text, "changed model answer"}
        ]
      ]
    }

    {:ok, events_agent} = Agent.start_link(fn -> [] end)
    emit = fn event -> Agent.update(events_agent, &[event | &1]) end

    assert {:ok, messages, _context} =
             Loop.run(
               [Message.user("go")],
               %{system_prompt: nil, messages: []},
               config,
               emit
             )

    events = Agent.get(events_agent, &Enum.reverse/1)
    Agent.stop(events_agent)

    assert List.last(messages).model == "faux-next"
    assert_guard_before_each_turn(events, 2)
  end

  test "prepare-next-turn config changes reach a queued follow-up", %{tmp: tmp, owner: owner} do
    next_model = %Model{id: "faux-follow-up", api: "faux", provider: "faux"}

    Hooks.register(
      :prepare_next_turn,
      fn {context, config}, ctx ->
        case ctx.cwd == tmp and config.model.id == "faux" do
          true -> {:ok, {context, Map.put(config, :model, next_model)}}
          false -> {:ok, {context, config}}
        end
      end,
      owner: owner
    )

    follow_up_count =
      start_supervised!({Agent, fn -> 0 end}, id: {:follow_up_count, make_ref()})

    get_follow_up = fn ->
      case Agent.get_and_update(follow_up_count, fn count -> {count, count + 1} end) do
        0 -> [Message.user("queued follow-up")]
        _later -> []
      end
    end

    config = %{
      provider: Catalyst.LLM.Faux,
      model: %Model{id: "faux", api: "faux", provider: "faux"},
      cwd: tmp,
      tools: [],
      opts: [script: [{:text, "first"}, {:text, "second"}]],
      get_follow_up: get_follow_up
    }

    assert {:ok, messages, _context} =
             Loop.run(
               [Message.user("go")],
               %{system_prompt: nil, messages: []},
               config,
               fn _event -> :ok end
             )

    assert Enum.map(Enum.filter(messages, &match?(%Message.Assistant{}, &1)), & &1.model) == [
             "faux",
             "faux-follow-up"
           ]
  end

  test "prepare-next-turn tools change overrides the retained tool source", %{
    tmp: tmp,
    owner: owner
  } do
    File.write!(Path.join(tmp, "tools-change.txt"), "fixture")

    Hooks.register(
      :prepare_next_turn,
      fn {context, config}, ctx ->
        case ctx.cwd == tmp do
          true -> {:ok, {context, Map.put(config, :tools, [])}}
          false -> {:ok, {context, config}}
        end
      end,
      owner: owner
    )

    # Turn 1 executes `read` normally; the hook then empties the tool set, so
    # turn 2's identical call must fail as an unknown tool instead of running
    # against the stale retained `:tool_source`.
    script = [
      {:tool, "read", %{"path" => "tools-change.txt"}},
      {:tool, "read", %{"path" => "tools-change.txt"}},
      {:text, "done"}
    ]

    config = %{
      provider: Catalyst.LLM.Faux,
      model: %Model{id: "faux", api: "faux", provider: "faux"},
      cwd: tmp,
      tools: Registry.default_tools(),
      opts: [script: script]
    }

    assert {:ok, messages, _context} =
             Loop.run(
               [Message.user("go")],
               %{system_prompt: nil, messages: []},
               config,
               fn _event -> :ok end
             )

    assert [first, second] = Enum.filter(messages, &match?(%Message.ToolResult{}, &1))
    refute first.is_error
    assert second.is_error
    assert Content.text_of(second.content) =~ "unknown tool"
  end

  test "prepare_next_turn also runs on a toolless (natural-stop) turn", %{tmp: tmp, owner: owner} do
    parent = self()

    Hooks.register(
      :prepare_next_turn,
      fn {context, config}, ctx ->
        if ctx.cwd == tmp, do: send(parent, {:prepared, ctx.tool_results})
        {:ok, {context, config}}
      end,
      owner: owner
    )

    run([{:text, "over"}], "go", tmp)

    assert_receive {:prepared, []}
  end

  test "should_stop_after_turn on a natural stop also skips the follow-up queue", %{
    tmp: tmp,
    owner: owner
  } do
    parent = self()

    Hooks.register(
      :should_stop_after_turn,
      fn ctx -> if ctx.cwd == tmp, do: true, else: :cont end,
      owner: owner
    )

    config = %{
      provider: Catalyst.LLM.Faux,
      model: %Model{id: "faux", api: "faux", provider: "faux"},
      cwd: tmp,
      tools: Registry.default_tools(),
      opts: [script: [{:text, "over"}]],
      get_follow_up: fn ->
        send(parent, :follow_up_drained)
        [Message.user("queued")]
      end
    }

    {:ok, msgs, _ctx} =
      Loop.run([Message.user("go")], %{system_prompt: nil, messages: []}, config, fn _ -> :ok end)

    # The hook vetoed continuing: one assistant turn, follow-ups untouched.
    assert Enum.count(msgs, &match?(%Message.Assistant{}, &1)) == 1
    refute_received :follow_up_drained
  end

  test "event observers receive loop events", %{tmp: tmp, owner: owner} do
    pid = self()
    Hooks.on(fn ev -> send(pid, {:obs, ev}) end, owner: owner)

    run([{:text, "hi"}], "go", tmp)

    assert_receive {:obs, %Event.AgentStart{}}
    assert_receive {:obs, %Event.AgentEnd{}}
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
end
