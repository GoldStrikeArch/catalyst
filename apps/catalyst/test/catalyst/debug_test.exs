defmodule Catalyst.DebugTest do
  use ExUnit.Case, async: false

  alias Catalyst.{Content, Debug}
  alias Catalyst.Agent.Event
  alias Catalyst.Tools.ReadLog

  setup do
    sid = "dbgtest_#{System.unique_integer([:positive])}"
    path = Debug.path(sid)

    on_exit(fn ->
      File.rm_rf(path)

      case File.read_link(Debug.latest_path()) do
        {:ok, ^path} -> File.rm(Debug.latest_path())
        _other -> :ok
      end
    end)

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

  test "tool results log image mime+size+digest, never image bytes", %{sid: sid} do
    data = Base.encode64(String.duplicate("pixels!", 50))

    Debug.log_event(sid, %Event.ToolExecutionEnd{
      call_id: "c",
      name: "computer",
      is_error: false,
      result: %{
        content: [
          %Content.Text{text: "Screenshot of display 1"},
          %Content.Image{data: data, mime_type: "image/png"}
        ],
        details: %{}
      }
    })

    content = File.read!(Debug.path(sid))
    assert content =~ "tool_end computer"
    assert content =~ "[image image/png #{byte_size(data)}B sha256:"
    refute content =~ data
  end

  test "describe_content and scrub_image_payloads keep image bytes out of logs" do
    data = Base.encode64(String.duplicate("x", 200))

    described =
      Debug.describe_content([
        %Content.Text{text: "note"},
        %Content.Image{data: data, mime_type: "image/png"}
      ])

    assert described =~ "note"
    assert described =~ "[image image/png"
    refute described =~ data

    body = ~s({"image_url":"data:image/png;base64,#{data}","other":"kept"})
    scrubbed = Debug.scrub_image_payloads(body)
    refute scrubbed =~ data
    assert scrubbed =~ "data:image/png;base64,<#{byte_size(data)}B elided>"
    assert scrubbed =~ ~s("other":"kept")

    # No data URL → byte-identical no-op.
    assert Debug.scrub_image_payloads(~s({"a":1})) == ~s({"a":1})
  end

  test "background debug writes complete outside the caller", %{sid: sid} do
    assert {:ok, log_pid} = Debug.log_async(sid, "async", "background line")
    assert {:ok, event_pid} = Debug.log_event_async(sid, %Event.AgentStart{})
    assert {:ok, latest_pid} = Debug.mark_latest_async(sid)

    await_background(log_pid)
    await_background(event_pid)
    await_background(latest_pid)

    content = File.read!(Debug.path(sid))
    assert content =~ "background line"
    assert content =~ "agent_start"
    assert File.read_link(Debug.latest_path()) == {:ok, Debug.path(sid)}
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

  # AUDIT: the scrubbing regex requires a payload of at least 64 base64
  # characters (48 bytes), so a small-but-valid inline image passes through
  # untouched. guide.md and architecture.md both state that debug logs "never
  # contain image bytes" — the threshold makes that claim false for any image
  # under 48 bytes (a 1x1 GIF is 43).
  @tag :audit
  test "a short inline image payload is elided like any other" do
    # A real 1x1 transparent GIF: 43 bytes, 58 base64 characters.
    gif =
      Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")

    payload = Base.encode64(gif)
    body = ~s({"image_url":"data:image/gif;base64,#{payload}"})

    scrubbed = Debug.scrub_image_payloads(body)

    refute scrubbed =~ payload, "short image payload survived scrubbing: #{scrubbed}"
    assert scrubbed =~ "elided"
  end

  defp await_background(pid) do
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
    assert reason in [:normal, :noproc]
  end
end
