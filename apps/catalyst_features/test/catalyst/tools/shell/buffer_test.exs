defmodule Catalyst.Tools.Shell.BufferTest do
  use ExUnit.Case, async: true

  doctest Catalyst.Tools.Shell.Buffer

  alias Catalyst.Tools.Shell.Buffer

  # AUDIT: `take/2` backs off over a split multibyte character, but when the
  # whole character is wider than the read budget the back-off lands on 0 — an
  # empty chunk that consumes nothing. `Shell.Server.deliver_chunk/3` then makes
  # no progress on this or any later read, so the caller can never drain the
  # leading character. `max_bytes` has a schema minimum of 1, so the model can
  # reach this. take/2 must always consume something when the buffer is
  # non-empty (return the whole character, or report that it does not fit).
  @tag :audit
  test "a read budget smaller than the leading character still makes progress" do
    for {text, budget} <- [{"é hello", 1}, {"€ hello", 2}, {"🙂 hello", 3}] do
      buffer = Buffer.new(100) |> Buffer.push(text)
      {chunk, rest} = Buffer.take(buffer, budget)

      assert chunk != "",
             "take/2 returned an empty chunk for #{inspect(text)} at max_bytes #{budget}"

      assert Buffer.size(rest) < byte_size(text)
    end
  end

  @tag :audit
  test "repeated small reads eventually drain the buffer" do
    drained =
      Enum.reduce_while(1..64, Buffer.new(100) |> Buffer.push("é"), fn _step, buffer ->
        case Buffer.take(buffer, 1) do
          {"", _rest} -> {:halt, :stalled}
          {_chunk, rest} -> {:cont, rest}
        end
      end)

    refute drained == :stalled, "the buffer never advanced under a 1-byte read budget"
  end
end
