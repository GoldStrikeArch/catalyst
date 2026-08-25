defmodule Catalyst.Session.ServerTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [wait_until: 1]

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Hooks, Message, Model}
  alias Catalyst.Session.{EventSink, Manager, Server, Store}

  setup do
    tmp = Path.join(System.tmp_dir!(), "catalyst_session_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "lib"))
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp, model: %Model{id: "faux", api: "faux", provider: "faux"}}
  end

  defp start(tmp, model, script) do
    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(
        cwd: tmp,
        provider: Catalyst.LLM.Faux,
        model: model,
        opts: [script: script]
      )

    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))
    {id, pid}
  end

  test "runs an end-to-end turn: transcript, events, JSONL persistence", %{tmp: tmp, model: model} do
    File.write!(Path.join(tmp, "lib/g.ex"), "defmodule G do\n  def h, do: IO.puts(\"hi\")\nend\n")

    script = [
      {:tool, "read", %{"path" => "lib/g.ex"}},
      {:tool, "ast_grep",
       %{
         "pattern" => "IO.puts($A)",
         "rewrite" => "Logger.info($A)",
         "lang" => "elixir",
         "path" => "lib/g.ex"
       }},
      {:text, "rewrote it"}
    ]

    {id, pid} = start(tmp, model, script)
    assert :ok = Server.prompt(pid, "rewrite the puts")

    # The loop streams events over PubSub, tagged with the session id so a
    # subscriber that switched sessions can drop stale ones; wait for completion.
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 5000

    snap = Server.state(pid)
    refute snap.running

    # user + 3 assistant + 2 tool results
    assert length(snap.messages) == 6
    assert %Message.User{} = hd(snap.messages)
    assert Content.text_of(List.last(snap.messages).content) == "rewrote it"

    # File was actually rewritten by ast-grep.
    assert File.read!(Path.join(tmp, "lib/g.ex")) =~ "Logger.info(\"hi\")"

    # JSONL persisted and reloadable to the same transcript length.
    assert File.exists?(snap.store_path)
    assert length(Store.load(snap.store_path)) == 6
  end

  test "rejects a second prompt while running, then accepts after", %{tmp: tmp, model: model} do
    # A slow first turn so we can observe the busy state.
    script = [{:tool, "bash", %{"command" => "sleep 1"}}, {:text, "done"}]
    {_id, pid} = start(tmp, model, script)

    assert :ok = Server.prompt(pid, "go")
    assert {:error, :busy} = Server.prompt(pid, "again")

    assert_receive {:agent_event, _, %Event.AgentEnd{}}, 5000
    assert :ok = Server.prompt(pid, "once more")
  end

  test "submit starts when idle and atomically queues when busy", %{tmp: tmp, model: model} do
    script = [{:tool, "bash", %{"command" => "sleep 1"}}, {:text, "done"}]
    {_id, pid} = start(tmp, model, script)

    assert {:ok, :started} = Server.submit(pid, "first")
    assert {:ok, :queued} = Server.submit(pid, "second")
    assert_receive {:agent_event, _, %Event.AgentEnd{}}, 5000

    users = Enum.filter(Server.state(pid).messages, &match?(%Message.User{}, &1))
    assert Enum.map(users, &Content.text_of(&1.content)) == ["first", "second"]
  end

  test "a session restarted with the same id resumes its transcript", %{tmp: tmp, model: model} do
    script = [{:text, "first reply"}]
    {id, pid} = start(tmp, model, script)

    assert :ok = Server.prompt(pid, "hello")
    assert_receive {:agent_event, _, %Event.AgentEnd{}}, 5000

    Manager.stop(id)
    wait_until(fn -> Manager.whereis(id) == :error end)

    {:ok, %{pid: pid2}} =
      Manager.start_session(
        id: id,
        cwd: tmp,
        provider: Catalyst.LLM.Faux,
        model: model,
        opts: [script: script]
      )

    snap = Server.state(pid2)
    assert [%Message.User{}, %Message.Assistant{} = a] = snap.messages
    assert Content.text_of(a.content) == "first reply"
  end

  test "a resumed session keeps its configured model and thinking level", %{
    tmp: tmp,
    model: model
  } do
    {id, pid} = start(tmp, model, [{:text, "ok"}])

    switched = %Model{id: "faux-turbo", api: "faux", provider: "faux", input: [:text]}
    :ok = Server.configure(pid, model: switched, opts: [reasoning_effort: "high"])

    Manager.stop(id)
    wait_until(fn -> Manager.whereis(id) == :error end)

    # Restarted with the ORIGINAL model in opts: the persisted
    # model_change/thinking_level_change entries must win.
    {:ok, %{pid: pid2}} =
      Manager.start_session(
        id: id,
        cwd: tmp,
        provider: Catalyst.LLM.Faux,
        model: model,
        opts: [script: [{:text, "ok"}]]
      )

    snap = Server.state(pid2)
    assert snap.model.id == "faux-turbo"
    assert Keyword.get(snap.opts, :reasoning_effort) == "high"
  end

  test "cleared model and thinking level stay cleared after restart", %{
    tmp: tmp,
    model: model
  } do
    {id, pid} = start(tmp, model, [{:text, "ok"}])

    switched = %Model{id: "faux-turbo", api: "faux", provider: "faux"}
    :ok = Server.configure(pid, model: switched, opts: [reasoning_effort: "high"])
    :ok = Server.configure(pid, model: nil, opts: [reasoning_effort: nil])

    Manager.stop(id)
    wait_until(fn -> Manager.whereis(id) == :error end)

    {:ok, %{pid: pid2}} =
      Manager.start_session(
        id: id,
        cwd: tmp,
        provider: Catalyst.LLM.Faux,
        model: model,
        opts: [script: [{:text, "ok"}], reasoning_effort: "medium"]
      )

    snap = Server.state(pid2)
    assert snap.model == nil
    refute Keyword.has_key?(snap.opts, :reasoning_effort)
  end

  test "a resumed session keeps its configured workflow and system prompt override", %{
    tmp: tmp,
    model: model
  } do
    {id, pid} = start(tmp, model, [{:text, "ok"}])

    :ok =
      Server.configure(pid,
        system_prompt: "You are the review bot.",
        opts: [workflow: "review"]
      )

    Manager.stop(id)
    wait_until(fn -> Manager.whereis(id) == :error end)

    # Restarted WITHOUT the workflow/prompt: the persisted snapshot must win.
    {:ok, %{pid: pid2}} =
      Manager.start_session(
        id: id,
        cwd: tmp,
        provider: Catalyst.LLM.Faux,
        model: model,
        opts: [script: [{:text, "ok"}]]
      )

    snap = Server.state(pid2)
    assert Keyword.get(snap.opts, :workflow) == "review"
    assert snap.system_prompt == "You are the review bot."
  end

  test "cleared workflow and system prompt stay cleared after restart", %{
    tmp: tmp,
    model: model
  } do
    {id, pid} = start(tmp, model, [{:text, "ok"}])

    :ok = Server.configure(pid, system_prompt: "pinned", opts: [workflow: "review"])
    :ok = Server.configure(pid, system_prompt: nil, opts: [workflow: nil])

    Manager.stop(id)
    wait_until(fn -> Manager.whereis(id) == :error end)

    # Restarted WITH a boot-time workflow/prompt: the persisted clear
    # tombstones must still win over the caller's defaults.
    {:ok, %{pid: pid2}} =
      Manager.start_session(
        id: id,
        cwd: tmp,
        provider: Catalyst.LLM.Faux,
        model: model,
        system_prompt: "boot default",
        workflow: "boot-flow",
        opts: [script: [{:text, "ok"}]]
      )

    snap = Server.state(pid2)
    refute Keyword.has_key?(snap.opts, :workflow)
    assert snap.system_prompt == nil
  end

  test "configure rejects a blank or non-binary system prompt unchanged", %{
    tmp: tmp,
    model: model
  } do
    {_id, pid} = start(tmp, model, [{:text, "ok"}])

    :ok = Server.configure(pid, system_prompt: "keep me")

    assert {:error, {:invalid_system_prompt, "   "}} =
             Server.configure(pid, system_prompt: "   ")

    assert {:error, {:invalid_system_prompt, 42}} = Server.configure(pid, system_prompt: 42)

    # The rejected calls changed nothing — including the persisted snapshot.
    snap = Server.state(pid)
    assert snap.system_prompt == "keep me"

    settings = Store.load_settings(snap.store_path)
    assert settings.system_prompt == "keep me"
  end

  test "manager rejects unsafe session ids before starting a server", %{tmp: tmp} do
    for id <- ["../escape", "nested/id", "", :not_a_string] do
      assert {:error, {:invalid_session_id, ^id}} = Manager.start_session(id: id, cwd: tmp)
    end

    assert :error = Manager.whereis("../escape")
  end

  test "nested opts cannot replace the validated session id", %{tmp: tmp, model: model} do
    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(
        cwd: tmp,
        provider: Catalyst.LLM.Faux,
        model: model,
        opts: [session_id: "../../outside", script: [{:text, "ok"}]]
      )

    snapshot = Server.state(pid)
    refute Keyword.has_key?(snapshot.opts, :session_id)
    assert Path.basename(snapshot.store_path) == "#{id}.jsonl"

    assert :ok = Server.configure(pid, opts: [session_id: "../still-outside"])
    refute Keyword.has_key?(Server.state(pid).opts, :session_id)
  end

  test "abort kills the run and synthesizes an aborted turn", %{tmp: tmp, model: model} do
    script = [{:tool, "bash", %{"command" => "sleep 30"}}, {:text, "unreached"}]
    {id, pid} = start(tmp, model, script)
    owner = make_ref()
    test_pid = self()

    :ok =
      Hooks.on(
        fn
          %Event.AgentEnd{} = event -> send(test_pid, {:observed_agent_end, event})
          _event -> :ok
        end,
        owner: owner
      )

    on_exit(fn -> Hooks.unregister(owner) end)

    assert :ok = Server.prompt(pid, "long task")
    Server.abort(pid)

    assert_receive {:agent_event, _, %Event.AgentEnd{}}, 5000
    assert :ok = Hooks.await_observers(id)
    assert_receive {:observed_agent_end, %Event.AgentEnd{}}, 1_000
    refute_receive {:observed_agent_end, %Event.AgentEnd{}}

    snap = Server.state(pid)
    assert snap.error_message == "Run aborted."
    assert Enum.any?(snap.messages, &match?(%Message.Assistant{stop_reason: :aborted}, &1))
  end

  test "abort mid-tool synthesizes results for orphaned tool calls", %{tmp: tmp, model: model} do
    script = [{:tool, "bash", %{"command" => "sleep 30"}}, {:text, "unreached"}]
    {_id, pid} = start(tmp, model, script)

    assert :ok = Server.prompt(pid, "long task")
    # The assistant message carrying the tool call is folded (and persisted)
    # before the tool starts — abort after that, mid-tool.
    assert_receive {:agent_event, _, %Event.ToolExecutionStart{}}, 5000
    Server.abort(pid)
    assert_receive {:agent_event, _, %Event.AgentEnd{}}, 5000

    snap = Server.state(pid)

    call_ids =
      for %Message.Assistant{} = a <- snap.messages,
          %Content.ToolCall{id: id} <- Message.tool_calls(a),
          do: id

    assert call_ids != []

    # Every persisted tool call has a result — a transcript with a call but no
    # output is rejected by providers on every subsequent request, so an abort
    # without synthesis would brick the session.
    result_ids = for %Message.ToolResult{tool_call_id: id} <- snap.messages, do: id
    assert Enum.all?(call_ids, &(&1 in result_ids))
    assert Enum.any?(snap.messages, &match?(%Message.ToolResult{is_error: true}, &1))

    # And the synthesized results are persisted, so a resume stays replayable.
    reloaded_ids =
      for %Message.ToolResult{tool_call_id: id} <- Store.load(snap.store_path), do: id

    assert Enum.all?(call_ids, &(&1 in reloaded_ids))
  end

  test "a session stopped mid-tool repairs dangling tool calls on resume", %{
    tmp: tmp,
    model: model
  } do
    script = [{:tool, "bash", %{"command" => "sleep 30"}}, {:text, "unreached"}]
    {id, pid} = start(tmp, model, script)

    assert :ok = Server.prompt(pid, "long task")
    # The assistant message carrying the tool call is persisted before the tool
    # starts — stopping the session here leaves it dangling in the JSONL, with
    # no abort/DOWN path to synthesize results (same shape as a hard VM crash).
    assert_receive {:agent_event, _, %Event.ToolExecutionStart{}}, 5000

    Manager.stop(id)
    wait_until(fn -> Manager.whereis(id) == :error end)

    {:ok, %{pid: pid2}} =
      Manager.start_session(
        id: id,
        cwd: tmp,
        provider: Catalyst.LLM.Faux,
        model: model,
        opts: [script: [{:text, "resumed"}]]
      )

    snap = Server.state(pid2)

    call_ids =
      for %Message.Assistant{} = a <- snap.messages,
          %Content.ToolCall{id: cid} <- Message.tool_calls(a),
          do: cid

    assert call_ids != []

    # Load-time repair: every persisted tool call has a synthesized error
    # result, so the resumed transcript stays replayable.
    result_ids = for %Message.ToolResult{tool_call_id: cid} <- snap.messages, do: cid
    assert Enum.all?(call_ids, &(&1 in result_ids))
    assert Enum.any?(snap.messages, &match?(%Message.ToolResult{is_error: true}, &1))

    # The repair is persisted too — the NEXT restart must not need it again.
    reloaded_ids =
      for %Message.ToolResult{tool_call_id: cid} <- Store.load(snap.store_path), do: cid

    assert Enum.all?(call_ids, &(&1 in reloaded_ids))
  end

  test "reset clears the transcript, aborts the run, and survives a restart", %{
    tmp: tmp,
    model: model
  } do
    script = [{:tool, "bash", %{"command" => "sleep 30"}}, {:text, "unreached"}]
    {id, pid} = start(tmp, model, script)

    assert :ok = Server.prompt(pid, "long task")
    Server.reset(pid)

    # Subscribers waiting on the aborted run are unlocked.
    assert_receive {:agent_event, _, %Event.AgentEnd{}}, 5000

    snap = Server.state(pid)
    assert snap.messages == []
    refute snap.running

    # The reset marker persists: a restart with the same id stays cleared.
    Manager.stop(id)
    wait_until(fn -> Manager.whereis(id) == :error end)

    {:ok, %{pid: pid2}} =
      Manager.start_session(
        id: id,
        cwd: tmp,
        provider: Catalyst.LLM.Faux,
        model: model,
        opts: [script: [{:text, "fresh"}]]
      )

    assert Server.state(pid2).messages == []
  end

  test "a failed reset marker leaves the live transcript and run untouched", %{
    tmp: tmp,
    model: model
  } do
    script = [{:tool, "bash", %{"command" => "sleep 30"}}, {:text, "unreached"}]
    {_id, pid} = start(tmp, model, script)

    assert :ok = Server.prompt(pid, "do not clear or stop")
    assert_receive {:agent_event, _, %Event.ToolExecutionStart{}}, 5_000

    before = Server.state(pid)
    assert before.running

    File.rm!(before.store_path)
    File.mkdir_p!(before.store_path)

    assert {:error, {:write_failed, _reason}} = Server.reset(pid)
    after_failed_reset = Server.state(pid)

    assert after_failed_reset.messages == before.messages
    assert after_failed_reset.running == before.running
    assert after_failed_reset.pending_tool_calls == before.pending_tool_calls

    # Restore a writable append target before aborting the intentionally long
    # command, so the test leaves no live worker or noisy persistence failures.
    File.rm_rf!(before.store_path)
    File.write!(before.store_path, "")
    Server.abort(pid)
    assert_receive {:agent_event, _, %Event.AgentEnd{}}, 5_000
  end

  test "configure applies model/opts to the next run without restarting", %{
    tmp: tmp,
    model: model
  } do
    {_id, pid} = start(tmp, model, [{:text, "first"}])

    new_model = %Model{id: "faux-2", api: "faux", provider: "faux"}

    :ok =
      Server.configure(pid,
        model: new_model,
        opts: [reasoning_effort: "high", service_tier: "priority"]
      )

    snap = Server.state(pid)
    assert snap.model.id == "faux-2"
    assert snap.opts[:reasoning_effort] == "high"
    assert snap.opts[:service_tier] == "priority"
    # The original session opts (the Faux script) survive the merge.
    assert snap.opts[:script] == [{:text, "first"}]

    # A nil value DELETES the key (turning Fast off removes service_tier).
    :ok = Server.configure(pid, opts: [service_tier: nil])
    refute Keyword.has_key?(Server.state(pid).opts, :service_tier)
  end

  test "a session without a provider persists a tagged run error instead of crashing", %{tmp: tmp} do
    {:ok, %{id: id, pid: pid}} = Manager.start_session(cwd: tmp, provider: nil, model: nil)
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    assert :ok = Server.prompt(pid, "hello")
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    _ = :sys.get_state(pid)

    assert [%Message.User{}, %Message.Assistant{stop_reason: :error} = error] =
             Server.state(pid).messages

    assert error.error_message =~ ":no_provider"
  end

  test "a populated session rejects switching into an external backend", %{
    tmp: tmp,
    model: model
  } do
    owner = "session_server_external_workflow"

    assert :ok =
             Catalyst.Workflow.Registry.register_workflow(
               "external-test",
               Catalyst.Test.ExternalWorkflow,
               owner: owner
             )

    on_exit(fn -> Catalyst.Runtime.Registry.purge_owner(owner) end)
    {_id, pid} = start(tmp, model, [])

    assert :ok =
             Server.append_recovered(pid, %Message.Assistant{
               content: Content.text("existing"),
               timestamp: Message.now()
             })

    assert {:error, :backend_switch_requires_new_session} =
             Server.configure(pid, opts: [workflow: "external-test"])

    assert {:error, :backend_switch_requires_new_session} =
             Server.configure(pid, opts: [loop: Catalyst.Test.ExternalWorkflow])

    refute Keyword.has_key?(Server.state(pid).opts, :workflow)
    refute Keyword.has_key?(Server.state(pid).opts, :loop)
  end

  test "an active first run cannot switch backends before its prompt is persisted", %{tmp: tmp} do
    ref = make_ref()

    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(
        cwd: tmp,
        provider: nil,
        model: nil,
        opts: [
          loop: Catalyst.Test.BlockingWorkflow,
          blocking_test_pid: self(),
          blocking_ref: ref
        ]
      )

    on_exit(fn -> Manager.stop(id) end)
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    assert :ok = Server.prompt(pid, "first")
    assert_receive {:blocking_workflow_started, ^ref, worker}, 1_000
    assert %{running: true, messages: []} = Server.state(pid)

    assert {:error, :backend_switch_requires_new_session} =
             Server.configure(pid, opts: [loop: Catalyst.Test.ExternalWorkflow])

    send(worker, {:release_blocking_workflow, ref})
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
  end

  test "events from a dead run are dropped (abort race)", %{tmp: tmp, model: model} do
    script = [{:tool, "bash", %{"command" => "sleep 30"}}, {:text, "unreached"}]
    {_id, pid} = start(tmp, model, script)

    assert :ok = Server.prompt(pid, "long task")
    Server.abort(pid)
    assert_receive {:agent_event, _, %Event.AgentEnd{}}, 5000

    before = Server.state(pid).messages

    # A buffered event from the killed run carries a stale ref and must not
    # fold into (or persist after) the synthesized abort state.
    stale = %Event.MessageEnd{message: Catalyst.Message.user("stale")}
    GenServer.cast(pid, {:agent_event, make_ref(), stale})

    assert Server.state(pid).messages == before
  end

  test "a durable compaction appends and folds before observers see it", %{
    tmp: tmp,
    model: model
  } do
    {id, pid} = start(tmp, model, [])
    run_ref = install_run_ref(pid)
    owner = make_ref()
    test_pid = self()

    :ok = Hooks.on(fn event -> send(test_pid, {:observed, event}) end, owner: owner)
    on_exit(fn -> Hooks.unregister(owner) end)

    event = %Event.ContextCompacted{replacement: [Message.user("durable replacement")]}

    assert :ok = EventSink.persist(pid, run_ref, event)
    assert_receive {:agent_event, ^id, ^event}
    assert :ok = Hooks.await_observers(id)
    assert_receive {:observed, ^event}
    refute_receive {:observed, ^event}

    assert [message] = Server.state(pid).messages
    assert Content.text_of(message.content) == "durable replacement"
    assert [persisted] = Store.load(Server.state(pid).store_path)
    assert Content.text_of(persisted.content) == "durable replacement"
  end

  test "durable observer admission survives the persistence caller exiting", %{
    tmp: tmp,
    model: model
  } do
    {id, pid} = start(tmp, model, [])
    run_ref = install_run_ref(pid)
    owner = make_ref()
    test_pid = self()

    :ok = Hooks.on(fn event -> send(test_pid, {:observed_after_exit, event}) end, owner: owner)
    on_exit(fn -> Hooks.unregister(owner) end)

    event = %Event.ContextCompacted{replacement: [Message.user("committed before exit")]}

    caller =
      start_supervised!(
        {Task,
         fn ->
           :ok = EventSink.persist(pid, run_ref, event)
         end}
      )

    caller_ref = Process.monitor(caller)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, 1_000
    assert :ok = Hooks.await_observers(id)
    assert_receive {:observed_after_exit, ^event}
    refute_receive {:observed_after_exit, ^event}
  end

  test "a failed durable compaction is neither folded, broadcast, nor observed", %{
    tmp: tmp,
    model: model
  } do
    {id, pid} = start(tmp, model, [])
    run_ref = install_run_ref(pid)
    owner = make_ref()
    test_pid = self()
    store_path = Server.state(pid).store_path

    :ok = Hooks.on(fn event -> send(test_pid, {:observed, event}) end, owner: owner)
    on_exit(fn -> Hooks.unregister(owner) end)

    File.rm!(store_path)
    File.mkdir_p!(store_path)

    event = %Event.ContextCompacted{replacement: [Message.user("must not install")]}

    assert {:error, {:write_failed, _reason}} = EventSink.persist(pid, run_ref, event)
    assert Server.state(pid).messages == []
    refute_receive {:agent_event, ^id, ^event}
    assert :ok = Hooks.await_observers(id)
    refute_receive {:observed, ^event}
  end

  test "a stale drain is a no-op: queued steering survives for the next run", %{
    tmp: tmp,
    model: model
  } do
    {_id, pid} = start(tmp, model, [{:text, "reply"}])

    # Replay the drain/abort race: a message is queued with no run active, and
    # a dead run's buffered drain call (its ref is no longer current) arrives.
    # It must reply [] without moving the queued message into in_flight — the
    # next run's AgentEnd clears in_flight, which would silently drop it.
    Server.steer(pid, "do not lose me")
    assert GenServer.call(pid, {:drain_steering, make_ref()}) == []
    assert GenServer.call(pid, {:drain_follow_up, make_ref()}) == []

    # The message is still queued, so the next run drains it into the transcript.
    assert :ok = Server.prompt(pid, "go")
    assert_receive {:agent_event, _, %Event.AgentEnd{}}, 5000

    user_texts =
      for %Message.User{content: c} <- Server.state(pid).messages, do: Content.text_of(c)

    assert "do not lose me" in user_texts
  end

  test "steering and follow-ups queued mid-run drain into the transcript", %{
    tmp: tmp,
    model: model
  } do
    # A slow tool turn leaves the queues time to fill before the next drain.
    script = [{:tool, "bash", %{"command" => "sleep 1"}}, {:text, "done"}]
    {_id, pid} = start(tmp, model, script)

    assert :ok = Server.prompt(pid, "go")
    Server.steer(pid, "change of plan")
    Server.follow_up(pid, "and after that")

    assert_receive {:agent_event, _, %Event.AgentEnd{}}, 5000

    snap = Server.state(pid)
    user_texts = for %Message.User{content: c} <- snap.messages, do: Content.text_of(c)

    assert "change of plan" in user_texts
    assert "and after that" in user_texts
  end

  defp install_run_ref(pid) do
    run_ref = make_ref()
    :sys.replace_state(pid, &%{&1 | run_ref: run_ref})
    run_ref
  end
end
