defmodule Catalyst.LLM.SSETest do
  # async: false — one test raises the global Logger level to capture a debug log.
  use ExUnit.Case, async: false
  alias Catalyst.LLM.SSE

  test "decodes complete frames and buffers a partial one" do
    {buf, events} = SSE.feed("", "event: a\ndata: {\"x\":1}\n\ndata: {\"y\":2}\n\ndata: {\"z\"")
    assert events == [%{"x" => 1}, %{"y" => 2}]
    # the trailing partial frame is carried over
    {_buf, events2} = SSE.feed(buf, ":3}\n\n")
    assert events2 == [%{"z" => 3}]
  end

  test "ignores [DONE] and non-data lines, handles CRLF" do
    {_buf, events} = SSE.feed("", "event: x\r\ndata: {\"a\":1}\r\n\r\ndata: [DONE]\r\n\r\n")
    assert events == [%{"a" => 1}]
  end

  test "joins multi-line data fields" do
    {_buf, events} = SSE.feed("", "data: {\"a\":\ndata: 1}\n\n")
    assert events == [%{"a" => 1}]
  end

  test "decodes a data line with no space after the colon" do
    {_buf, events} = SSE.feed("", "data:{\"a\":1}\n\n")
    assert events == [%{"a" => 1}]
  end

  test "strips at most one leading space after data: (SSE spec)" do
    # Two spaces: only one is field-syntax, the other belongs to the payload.
    # JSON tolerates the leading space, so the event still decodes.
    {_buf, events} = SSE.feed("", "data:  {\"a\":1}\n\n")
    assert events == [%{"a" => 1}]
  end

  test "handles a CRLF frame boundary split across chunks" do
    {buf, events} = SSE.feed("", "data: {\"a\":1}\r\n")
    assert events == []

    {buf, events} = SSE.feed(buf, "\r\ndata: {\"b\":2}\r\n\r")
    assert events == [%{"a" => 1}]

    {_buf, events} = SSE.feed(buf, "\n")
    assert events == [%{"b" => 2}]
  end

  test "handles mixed LF/CRLF blank-line boundaries" do
    {_buf, events} = SSE.feed("", "data: {\"a\":1}\n\r\ndata: {\"b\":2}\r\n\n")
    assert events == [%{"a" => 1}, %{"b" => 2}]
  end

  test "decodes a large frame fed in many small chunks" do
    big = String.duplicate("x", 200_000)
    frame = "data: " <> Jason.encode!(%{"big" => big, "n" => 7}) <> "\n\n"

    {buf, events} =
      frame
      |> chunk_every(64)
      |> Enum.reduce({"", []}, fn chunk, {buf, acc} ->
        {buf, events} = SSE.feed(buf, chunk)
        {buf, acc ++ events}
      end)

    assert buf == ""
    assert [%{"big" => ^big, "n" => 7}] = events
  end

  test "drops malformed JSON frames (logged at debug) and keeps decoding" do
    # The test config caps Logger at :warning; lower it so the debug log emits.
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        {_buf, events} = SSE.feed("", "data: {not json}\n\ndata: {\"ok\":true}\n\n")
        assert events == [%{"ok" => true}]
      end)

    assert log =~ "malformed JSON"
  end

  test "drops frames that decode to a non-object" do
    {_buf, events} = SSE.feed("", "data: 42\n\ndata: {\"ok\":1}\n\n")
    assert events == [%{"ok" => 1}]
  end

  defp chunk_every(binary, size) do
    binary
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.map(&:binary.list_to_bin/1)
  end
end
