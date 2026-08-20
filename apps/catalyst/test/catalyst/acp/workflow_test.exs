defmodule Catalyst.ACP.WorkflowTest do
  use ExUnit.Case, async: false

  alias Catalyst.ACP.{Agent, Client}
  alias Catalyst.Agent.Event
  alias Catalyst.Content
  alias Catalyst.Context.Transcript
  alias Catalyst.Message
  alias Catalyst.Session.{Manager, Server}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "catalyst_acp_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "streams, persists, auto-approves, and resumes after a Catalyst session restart", %{
    tmp: tmp
  } do
    permission_log = Path.join(tmp, "permission.json")

    agent = fixture_agent(permission_log)

    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(session_options(tmp, agent))

    on_exit(fn -> Manager.stop(id) end)
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    assert :ok = Server.prompt(pid, "first")
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 3_000
    _ = :sys.get_state(pid)

    assert File.read!(permission_log) =~ ~s("optionId":"allow-always")
    assert_transcript(Server.state(pid).messages, 1)

    [{client, _value}] = Registry.lookup(Catalyst.ACP.Registry, {id, "fixture"})
    assert %{recovery: :new, session_id: "fixture-session"} = Client.info(client)

    assert get_in(Client.info(client), [:session, :config_options, Access.at(0), "currentValue"]) ==
             "code"

    monitor = Process.monitor(client)
    assert :ok = Manager.stop(id)
    assert_receive {:DOWN, ^monitor, :process, ^client, _reason}, 1_000

    {:ok, %{pid: resumed_pid}} =
      id
      |> session_options(tmp, agent)
      |> Manager.start_session()

    assert :ok = Server.prompt(resumed_pid, "second")
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 3_000
    _ = :sys.get_state(resumed_pid)

    assert_transcript(Server.state(resumed_pid).messages, 2)

    [{resumed_client, _value}] = Registry.lookup(Catalyst.ACP.Registry, {id, "fixture"})
    assert %{recovery: :resume, session_id: "fixture-session"} = Client.info(resumed_client)

    log = File.read!(permission_log)
    assert log =~ ~s("method":"session/resume")
    assert occurrences(log, ~s("method":"session/new")) == 1

    monitor = Process.monitor(resumed_client)
    assert :ok = Manager.stop(id)
    assert_receive {:DOWN, ^monitor, :process, ^resumed_client, _reason}, 1_000
  end

  test "falls back to session/load and suppresses replayed history", %{tmp: tmp} do
    log_path = Path.join(tmp, "load.json")
    agent = fixture_agent(log_path, [{"ACP_FIXTURE_RECOVERY", "load"}])

    {:ok, %{id: id, pid: pid}} = Manager.start_session(session_options(tmp, agent))
    on_exit(fn -> Manager.stop(id) end)
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    assert :ok = Server.prompt(pid, "first")
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 3_000

    [{client, _value}] = Registry.lookup(Catalyst.ACP.Registry, {id, "fixture"})
    monitor = Process.monitor(client)
    Process.exit(client, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^client, :killed}, 1_000

    assert :ok = Server.prompt(pid, "second")
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 3_000
    _ = :sys.get_state(pid)

    messages = Server.state(pid).messages
    assert_transcript(messages, 2)
    refute Enum.any?(messages, &(Content.text_of(&1.content) == "replayed history"))

    [{loaded_client, _value}] = Registry.lookup(Catalyst.ACP.Registry, {id, "fixture"})
    assert %{recovery: :load} = Client.info(loaded_client)
    assert File.read!(log_path) =~ ~s("method":"session/load")
  end

  test "groups concurrent tool calls with all results in one valid transcript unit", %{tmp: tmp} do
    log_path = Path.join(tmp, "parallel.json")
    agent = fixture_agent(log_path, [{"ACP_FIXTURE_PROMPT", "parallel"}])

    {:ok, %{id: id, pid: pid}} = Manager.start_session(session_options(tmp, agent))
    on_exit(fn -> Manager.stop(id) end)
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    assert :ok = Server.prompt(pid, "parallel")
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 3_000
    _ = :sys.get_state(pid)

    messages = Server.state(pid).messages
    assert :ok = Transcript.validate_transcript(messages)

    assistant_index =
      Enum.find_index(messages, fn
        %Message.Assistant{} = message -> length(Message.tool_calls(message)) == 2
        _message -> false
      end)

    assert is_integer(assistant_index)

    [
      %Message.Assistant{} = assistant,
      %Message.ToolResult{} = first,
      %Message.ToolResult{} = second
    ] =
      Enum.slice(messages, assistant_index, 3)

    assert Enum.map(Message.tool_calls(assistant), & &1.id) == ["tool-1", "tool-2"]
    assert [first.tool_call_id, second.tool_call_id] == ["tool-1", "tool-2"]
  end

  test "marks a tool without a terminal update as failed", %{tmp: tmp} do
    log_path = Path.join(tmp, "incomplete.json")
    agent = fixture_agent(log_path, [{"ACP_FIXTURE_PROMPT", "incomplete"}])

    {:ok, %{id: id, pid: pid}} = Manager.start_session(session_options(tmp, agent))
    on_exit(fn -> Manager.stop(id) end)
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    assert :ok = Server.prompt(pid, "incomplete")

    assert_receive {:agent_event, ^id,
                    %Event.ToolExecutionEnd{
                      call_id: "tool-incomplete",
                      is_error: true
                    }},
                   3_000

    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 3_000
    _ = :sys.get_state(pid)

    messages = Server.state(pid).messages
    assert :ok = Transcript.validate_transcript(messages)

    assert %Message.ToolResult{is_error: true} =
             Enum.find(messages, &match?(%Message.ToolResult{}, &1))
  end

  defp assert_transcript(messages, turns) do
    assert Enum.count(messages, &match?(%Message.User{}, &1)) == turns
    assert Enum.count(messages, &match?(%Message.ToolResult{}, &1)) == turns

    final = List.last(messages)
    assert %Message.Assistant{api: "acp", provider: "fixture"} = final
    assert final.response_id == "fixture-session"
    assert Content.text_of(final.content) == "fixture answer"
  end

  defp fixture_agent(log_path, extra_env \\ []) do
    {:ok, agent} =
      Agent.new(
        id: "fixture",
        name: "Fixture",
        command: System.find_executable("elixir"),
        args: [fixture_path()],
        env: [{"ACP_FIXTURE_LOG", log_path} | extra_env]
      )

    agent
  end

  defp session_options(id \\ nil, tmp, agent) do
    [
      id: id,
      cwd: tmp,
      provider: nil,
      model: nil,
      system_prompt: "unused",
      tools: [],
      opts: [
        loop: Catalyst.ACP.Workflow,
        acp_agent: Map.from_struct(agent),
        acp_prompt_timeout: 2_000
      ]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp occurrences(text, pattern), do: text |> String.split(pattern) |> length() |> Kernel.-(1)

  defp fixture_path do
    Path.expand("../../fixtures/acp_agent.exs", __DIR__)
  end
end
