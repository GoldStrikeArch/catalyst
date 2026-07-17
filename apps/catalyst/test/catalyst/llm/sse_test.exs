defmodule Catalyst.LLM.SSETest do
  use ExUnit.Case, async: true
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
end
