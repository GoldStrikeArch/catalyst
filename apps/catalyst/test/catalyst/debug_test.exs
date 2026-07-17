defmodule Catalyst.DebugTest do
  use ExUnit.Case, async: false

  alias Catalyst.{Content, Debug}
  alias Catalyst.Agent.Event
  alias Catalyst.Tools.ReadLog

  setup do
    sid = "dbgtest_#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(Debug.path(sid)) end)
    {:ok, sid: sid}
  end

  test "log writes lines and log_event formats events", %{sid: sid} do
    Debug.log(sid, "test", "hello world")
    Debug.log_event(sid, %Event.AgentStart{})

    Debug.log_event(sid, %Event.ToolExecutionStart{
      call_id: "c",
      name: "read",
      args: %{"path" => "x"}
    })

    content = File.read!(Debug.path(sid))
    assert content =~ "[test] hello world"
    assert content =~ "agent_start"
    assert content =~ "tool_start read"
  end

  test "read_log returns the tail for this session", %{sid: sid} do
    Debug.log(sid, "test", "needle-line")
    ctx = %{cwd: ".", call_id: "c", session_id: sid, report: fn _ -> :ok end}

    res = ReadLog.execute(%{"lines" => 50}, ctx)
    assert Content.text_of(res.content) =~ "needle-line"
  end

  test "streaming deltas are not logged", %{sid: sid} do
    Debug.log_event(sid, %Event.MessageUpdate{message: nil, llm_event: nil})
    refute File.exists?(Debug.path(sid))
  end

  test "truncate clamps long binaries", %{} do
    out = Debug.truncate(String.duplicate("a", 5000), 100)
    assert byte_size(out) < 200
    assert out =~ "…(+"
  end

  test "read_log is graceful with no session id" do
    res =
      ReadLog.execute(%{}, %{cwd: ".", call_id: "c", session_id: nil, report: fn _ -> :ok end})

    assert Content.text_of(res.content) =~ "no session id"
  end
end
