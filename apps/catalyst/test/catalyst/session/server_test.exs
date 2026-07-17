defmodule Catalyst.Session.ServerTest do
  use ExUnit.Case, async: false

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message, Model}
  alias Catalyst.Session.{Manager, Server, Store}

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

  test "a session restarted with the same id resumes its transcript", %{tmp: tmp, model: model} do
    script = [{:text, "first reply"}]
    {id, pid} = start(tmp, model, script)

    assert :ok = Server.prompt(pid, "hello")
    assert_receive {:agent_event, _, %Event.AgentEnd{}}, 5000

    Manager.stop(id)
    wait_until(fn -> Manager.whereis(id) == nil end)

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

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  test "abort kills the run and synthesizes an aborted turn", %{tmp: tmp, model: model} do
    script = [{:tool, "bash", %{"command" => "sleep 30"}}, {:text, "unreached"}]
    {_id, pid} = start(tmp, model, script)

    assert :ok = Server.prompt(pid, "long task")
    Server.abort(pid)

    assert_receive {:agent_event, _, %Event.AgentEnd{}}, 5000
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
    wait_until(fn -> Manager.whereis(id) == nil end)

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
    wait_until(fn -> Manager.whereis(id) == nil end)

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

  test "a session without a provider returns a tagged error instead of crashing", %{tmp: tmp} do
    {:ok, %{pid: pid}} = Manager.start_session(cwd: tmp, provider: nil, model: nil)

    assert {:error, :no_provider} = Server.prompt(pid, "hello")
    # The server survived the misconfiguration and stays usable.
    assert Server.state(pid).messages == []
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
end
