defmodule Catalyst.Tools.Shell.Buffer do
  @moduledoc """
  Bounded FIFO byte buffer for pending PTY output.

  Chunks are pushed as they arrive from the port; reads take from the front so
  no output is silently skipped between `read` calls. When the total exceeds
  the cap, the **oldest** bytes are dropped (the newest output is the useful
  part of a flooding terminal) and the drop is counted so the caller can
  surface a notice. ANSI escapes pass through untouched; only size is bounded.

  `take/2` backs off over trailing UTF-8 continuation bytes so a multibyte
  character split across two port chunks is never cut in half at the read
  boundary — the partial character stays buffered for the next read.
  """

  # `chunks` has no defstruct default: the macro would inline the queue as a
  # literal tuple, which Dialyzer rejects against :queue's opaque type. new/1
  # is the only constructor and builds the queue at runtime.
  defstruct [:chunks, bytes: 0, cap: 0, dropped: 0]

  @type t :: %__MODULE__{
          chunks: :queue.queue(binary()),
          bytes: non_neg_integer(),
          cap: pos_integer(),
          dropped: non_neg_integer()
        }

  @doc "A new empty buffer holding at most `cap` bytes."
  @spec new(pos_integer()) :: t()
  def new(cap) when is_integer(cap) and cap > 0,
    do: %__MODULE__{chunks: :queue.new(), cap: cap}

  @doc "Total buffered bytes."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{bytes: bytes}), do: bytes

  @doc "Bytes dropped (oldest-first) since the last `take/2`."
  @spec dropped(t()) :: non_neg_integer()
  def dropped(%__MODULE__{dropped: dropped}), do: dropped

  @doc "Append one port chunk, evicting oldest bytes past the cap."
  @spec push(t(), binary()) :: t()
  def push(%__MODULE__{} = buffer, data) when is_binary(data) do
    %{buffer | chunks: :queue.in(data, buffer.chunks), bytes: buffer.bytes + byte_size(data)}
    |> evict()
  end

  @doc """
  Take up to `max_bytes` from the front on a UTF-8-safe boundary.

  Returns `{binary, rest}` with a **non-empty** binary, or `{:empty, rest}`
  when nothing is buffered; the dropped-byte counter is reset on the returned
  rest (the caller reports it alongside the taken bytes). A take can never
  return an empty chunk that consumes nothing, so a reader always makes
  progress: when the leading complete character is wider than `max_bytes`,
  that whole character is returned anyway — overrunning a 1-3 byte budget by
  at most 3 bytes is the only way to stay UTF-8-safe without stalling.

  ## Examples

      iex> alias Catalyst.Tools.Shell.Buffer
      iex> {out, rest} = Buffer.new(100) |> Buffer.push("hello") |> Buffer.take(3)
      iex> {out, Buffer.size(rest)}
      {"hel", 2}

      iex> alias Catalyst.Tools.Shell.Buffer
      iex> {out, rest} = Buffer.new(100) |> Buffer.push("ab" <> "é") |> Buffer.take(3)
      iex> {out, Buffer.size(rest)}
      {"ab", 2}

      iex> alias Catalyst.Tools.Shell.Buffer
      iex> {out, rest} = Buffer.new(100) |> Buffer.push("é hello") |> Buffer.take(1)
      iex> {out, Buffer.size(rest)}
      {"é", 6}

      iex> alias Catalyst.Tools.Shell.Buffer
      iex> Buffer.new(100) |> Buffer.take(1) |> elem(0)
      :empty
  """
  @spec take(t(), pos_integer()) :: {binary(), t()} | {:empty, t()}
  def take(%__MODULE__{bytes: 0} = buffer, max_bytes)
      when is_integer(max_bytes) and max_bytes > 0,
      do: {:empty, buffer}

  def take(%__MODULE__{} = buffer, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    whole = buffer.chunks |> :queue.to_list() |> IO.iodata_to_binary()
    cut = whole |> min_cut(max_bytes) |> utf8_backoff(whole) |> ensure_progress(whole)
    rest_bin = binary_part(whole, cut, byte_size(whole) - cut)

    rest = %{buffer | chunks: chunks_of(rest_bin), bytes: byte_size(rest_bin), dropped: 0}
    {binary_part(whole, 0, cut), rest}
  end

  defp min_cut(whole, max_bytes), do: min(byte_size(whole), max_bytes)

  # Back off over up to 3 trailing bytes when the cut would land inside a
  # multibyte character: a continuation byte (0b10xxxxxx) right after the cut
  # means the preceding lead byte's character is incomplete.
  defp utf8_backoff(cut, whole) when cut > 0 and cut < byte_size(whole) do
    case continuation?(whole, cut) do
      true -> backoff_lead(cut, whole, 3)
      false -> cut
    end
  end

  defp utf8_backoff(cut, _whole), do: cut

  defp backoff_lead(cut, _whole, 0), do: cut
  defp backoff_lead(0, _whole, _budget), do: 0

  defp backoff_lead(cut, whole, budget) do
    case continuation?(whole, cut - 1) do
      true -> backoff_lead(cut - 1, whole, budget - 1)
      false -> cut - 1
    end
  end

  # The back-off landed on 0 because the leading character is wider than the
  # budget: take that whole character anyway so the reader always advances
  # (`whole` is non-empty here — take/2 handles the empty buffer up front).
  # An invalid lead byte falls back to a single byte — still progress.
  defp ensure_progress(0, whole), do: leading_char_width(whole)
  defp ensure_progress(cut, _whole), do: cut

  defp leading_char_width(<<char::utf8, _::binary>>), do: byte_size(<<char::utf8>>)
  defp leading_char_width(_invalid), do: 1

  defp continuation?(whole, at) do
    <<_::binary-size(^at), byte, _::binary>> = whole
    Bitwise.band(byte, 0b1100_0000) == 0b1000_0000
  end

  defp chunks_of(""), do: :queue.new()
  defp chunks_of(bin), do: :queue.in(bin, :queue.new())

  defp evict(%__MODULE__{bytes: bytes, cap: cap} = buffer) when bytes <= cap, do: buffer

  defp evict(%__MODULE__{} = buffer) do
    {{:value, oldest}, chunks} = :queue.out(buffer.chunks)

    case :queue.is_empty(chunks) and byte_size(oldest) > buffer.cap do
      # A single oversized chunk keeps its tail rather than vanishing whole.
      true ->
        excess = byte_size(oldest) - buffer.cap
        tail = binary_part(oldest, excess, buffer.cap)
        %{buffer | chunks: chunks_of(tail), bytes: buffer.cap, dropped: buffer.dropped + excess}

      false ->
        %{
          buffer
          | chunks: chunks,
            bytes: buffer.bytes - byte_size(oldest),
            dropped: buffer.dropped + byte_size(oldest)
        }
        |> evict()
    end
  end
end
