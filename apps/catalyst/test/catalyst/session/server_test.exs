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
      Manager.start_session(cwd: tmp, provider: Catalyst.LLM.Faux, model: model, opts: [script: script])

    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))
    {id, pid}
  end

  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, tries) do
    if fun.(), do: :ok, else: (Process.sleep(50); wait_until(fun, tries - 1))
  end

  test "runs an end-to-end turn: transcript, events, JSONL persistence", %{tmp: tmp, model: model} do
    File.write!(Path.join(tmp, "lib/g.ex"), "defmodule G do\n  def h, do: IO.puts(\"hi\")\nend\n")

    script = [
      {:tool, "read", %{"path" => "lib/g.ex"}},
      {:tool, "ast_grep",
       %{"pattern" => "IO.puts($A)", "rewrite" => "Logger.info($A)", "lang" => "elixir", "path" => "lib/g.ex"}},
      {:text, "rewrote it"}
    ]

    {_id, pid} = start(tmp, model, script)
    assert :ok = Server.prompt(pid, "rewrite the puts")

    # The loop streams events over PubSub; wait for completion.
    assert_receive {:agent_event, %Event.AgentEnd{}}, 5000

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

    assert_receive {:agent_event, %Event.AgentEnd{}}, 5000
    assert :ok = Server.prompt(pid, "once more")
  end

  test "abort kills the run and synthesizes an aborted turn", %{tmp: tmp, model: model} do
    script = [{:tool, "bash", %{"command" => "sleep 30"}}, {:text, "unreached"}]
    {_id, pid} = start(tmp, model, script)

    assert :ok = Server.prompt(pid, "long task")
    # Let the run reach the sleeping bash, then abort.
    Process.sleep(200)
    Server.abort(pid)

    wait_until(fn -> not Server.state(pid).running end, 60)
    snap = Server.state(pid)
    assert snap.error_message == "Run aborted."
    assert Enum.any?(snap.messages, &match?(%Message.Assistant{stop_reason: :aborted}, &1))
  end
end
