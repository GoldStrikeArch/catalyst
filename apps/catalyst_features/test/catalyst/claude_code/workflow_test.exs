defmodule Catalyst.ClaudeCode.WorkflowTest do
  use ExUnit.Case, async: false

  alias Catalyst.Agent.Event
  alias Catalyst.Content
  alias Catalyst.Message
  alias Catalyst.Session.{Manager, Server}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "catalyst_claude_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    executable = Path.join(tmp, "claude")
    File.cp!(fixture_path(), executable)
    File.chmod!(executable, 0o700)

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp, executable: executable}
  end

  test "streams, persists tools, and resumes a second print-mode prompt", %{
    tmp: tmp,
    executable: executable
  } do
    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(
        cwd: tmp,
        provider: nil,
        model: nil,
        tools: [],
        opts: [
          loop: Catalyst.ClaudeCode.Workflow,
          claude_executable: executable,
          claude_timeout: 2_000
        ]
      )

    on_exit(fn -> Manager.stop(id) end)
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    assert :ok = Server.prompt(pid, "first")
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 3_000
    _ = :sys.get_state(pid)

    assert_turn(Server.state(pid).messages, "first answer", 1)

    assert :ok = Server.prompt(pid, "second")
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 3_000
    _ = :sys.get_state(pid)

    assert_turn(Server.state(pid).messages, "resumed answer", 2)
  end

  defp assert_turn(messages, answer, turns) do
    assert Enum.count(messages, &match?(%Message.User{}, &1)) == turns
    assert Enum.count(messages, &match?(%Message.ToolResult{}, &1)) == turns

    final = List.last(messages)
    assert %Message.Assistant{api: "claude-code", provider: "claude-code"} = final
    assert final.response_id == "claude-fixture-session"
    assert Content.text_of(final.content) == answer
  end

  defp fixture_path do
    Path.expand("../../fixtures/claude_print.exs", __DIR__)
  end
end
