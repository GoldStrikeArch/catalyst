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

  test "debug logging and read_log replace invalid UTF-8", %{sid: sid} do
    Debug.log(sid, <<"cat", 255>>, <<"before", 254, "after">>)
    assert String.valid?(File.read!(Debug.path(sid)))

    File.write!(Debug.path(sid), <<"raw", 255, "bytes">>)
    ctx = %{cwd: ".", call_id: "c", session_id: sid, report: fn _ -> :ok end}
    output = ReadLog.execute(%{}, ctx) |> Map.fetch!(:content) |> Content.text_of()

    assert String.valid?(output)
    assert output == "raw�bytes"
    assert is_binary(Jason.encode!(output))
  end

  test "read_log schema rejects non-positive line counts" do
    assert get_in(ReadLog.parameters(), ["properties", "lines", "minimum"]) == 1
  end

  test "read_log caps a large requested tail", %{sid: sid} do
    path = Debug.path(sid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, String.duplicate("a", 60 * 1024))
    ctx = %{cwd: ".", call_id: "c", session_id: sid, report: fn _ -> :ok end}

    res = ReadLog.execute(%{"lines" => 10_000}, ctx)
    output = Content.text_of(res.content)

    assert byte_size(output) < 52 * 1024
    assert output =~ "output truncated"
    assert res.details.truncation.truncated
  end

  test "streaming deltas are not logged", %{sid: sid} do
    Debug.log_event(sid, %Event.MessageUpdate{llm_event: nil})
    refute File.exists?(Debug.path(sid))
  end

  test "truncate clamps long binaries", %{} do
    out = Debug.truncate(String.duplicate("a", 5000), 100)
    assert byte_size(out) < 200
    assert out =~ "…(+"
  end

  test "truncate preserves a valid UTF-8 boundary" do
    out = Debug.truncate("aéz", 2)

    assert String.valid?(out)
    assert out == "a…(+3B)"
  end

  test "logging recreates a cached directory after it is deleted", %{sid: sid} do
    Debug.log(sid, "test", "first")
    File.rm_rf!(Debug.dir())

    Debug.log(sid, "test", "second")

    assert File.read!(Debug.path(sid)) =~ "second"
  end

  test "read_log is graceful with no session id" do
    res =
      ReadLog.execute(%{}, %{cwd: ".", call_id: "c", session_id: nil, report: fn _ -> :ok end})

    assert Content.text_of(res.content) =~ "no session id"
  end
end
