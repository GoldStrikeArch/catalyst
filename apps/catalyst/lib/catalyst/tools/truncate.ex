defmodule Catalyst.Tools.Truncate do
  @moduledoc """
  Line/byte truncation for tool output (PI's `truncate.ts`).

  `head/2` keeps the first lines (files, grep); `tail/2` keeps the last lines
  (bash). Defaults: 2000 lines or 50 KB, whichever is hit first.
  """

  @default_max_lines 2000
  @default_max_bytes 50 * 1024

  @type info :: %{
          truncated: boolean(),
          truncated_by: :lines | :bytes | nil,
          total_lines: non_neg_integer(),
          output_lines: non_neg_integer(),
          total_bytes: non_neg_integer()
        }

  @doc "Default line budget for tool output."
  @spec default_max_lines() :: pos_integer()
  def default_max_lines, do: @default_max_lines

  @doc "Default byte budget for tool output."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc "Keep the first lines/bytes within budget."
  @spec head(String.t(), keyword()) :: {String.t(), info()}
  def head(content, opts \\ []) when is_binary(content) do
    truncate(content, opts, :head)
  end

  @doc """
  Replace invalid UTF-8 bytes with the replacement character (U+FFFD).

  Tool results become LLM request JSON, so every text block must be valid
  UTF-8 — `Jason.encode!` raises otherwise, after the content is already in
  the transcript.
  """
  @spec scrub_utf8(binary()) :: String.t()
  def scrub_utf8(bin) when is_binary(bin) do
    if String.valid?(bin), do: bin, else: do_scrub(bin, [])
  end

  defp do_scrub(<<c::utf8, rest::binary>>, acc), do: do_scrub(rest, [acc, <<c::utf8>>])
  defp do_scrub(<<_byte, rest::binary>>, acc), do: do_scrub(rest, [acc, "�"])
  defp do_scrub(<<>>, acc), do: IO.iodata_to_binary(acc)

  @doc """
  Append (head) or prepend (tail) an in-text truncation notice so the model
  can tell output was cut; the bare text is returned when nothing was.
  """
  @spec notice(String.t(), info(), :head | :tail) :: String.t()
  def notice(text, %{truncated: false}, _side), do: text

  def notice(text, info, :head),
    do: text <> "\n... [output truncated: showing first #{summary(info)}]"

  def notice(text, info, :tail),
    do: "... [output truncated: showing last #{summary(info)}]\n" <> text

  defp summary(%{truncated_by: :bytes} = info),
    do:
      "#{info.output_lines} of #{info.total_lines} lines (#{div(info.total_bytes, 1024)}KB total)"

  defp summary(info), do: "#{info.output_lines} of #{info.total_lines} lines"

  @doc "Keep the last lines/bytes within budget."
  @spec tail(String.t(), keyword()) :: {String.t(), info()}
  def tail(content, opts \\ []) when is_binary(content) do
    truncate(content, opts, :tail)
  end

  @doc """
  Finish a list-producing tool's output (grep/find/ls): when `:limited?`,
  append a `"... [showing first N of M <noun>]"` marker (or
  `"... [showing first N <noun>; more exist]"` when the true total is
  `:unknown` because the child's output was capped), then head-truncate and
  attach the standard truncation notice.

  Returns `{text, info}` so each tool keeps its own details keys.

  Options (all required): `:limited?` (boolean), `:limit` (pos_integer),
  `:total` (non_neg_integer or `:unknown`), `:noun` (e.g. `"matches"`).
  """
  @spec listing(String.t(), keyword()) :: {String.t(), info()}
  def listing(text, opts) when is_binary(text) do
    marked =
      append_limit_marker(
        text,
        Keyword.fetch!(opts, :limited?),
        Keyword.fetch!(opts, :limit),
        Keyword.fetch!(opts, :total),
        Keyword.fetch!(opts, :noun)
      )

    {body, info} = head(marked)
    {notice(body, info, :head), info}
  end

  defp append_limit_marker(text, false, _limit, _total, _noun), do: text

  defp append_limit_marker(text, true, limit, :unknown, noun),
    do: text <> "\n... [showing first #{limit} #{noun}; more exist]"

  defp append_limit_marker(text, true, limit, total, noun),
    do: text <> "\n... [showing first #{limit} of #{total} #{noun}]"

  defp truncate(content, opts, side) do
    max_lines = Keyword.get(opts, :max_lines, @default_max_lines)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    lines = split_lines(content)
    total_lines = length(lines)
    total_bytes = byte_size(content)

    {text, by_lines?} =
      case total_lines > max_lines do
        true ->
          {slice_lines(lines, max_lines, side), true}

        # Within budget: keep the content byte-identical (a trailing newline
        # is preserved, not re-joined away).
        false ->
          {content, false}
      end

    {text, by_bytes?} =
      case byte_size(text) > max_bytes do
        true -> {clamp_bytes(text, max_bytes, side), true}
        false -> {text, false}
      end

    truncated = by_lines? or by_bytes?

    by =
      cond do
        by_bytes? -> :bytes
        by_lines? -> :lines
        true -> nil
      end

    {text,
     %{
       truncated: truncated,
       truncated_by: by,
       total_lines: total_lines,
       output_lines: text |> split_lines() |> length(),
       total_bytes: total_bytes
     }}
  end

  defp slice_lines(lines, max_lines, :head), do: lines |> Enum.take(max_lines) |> Enum.join("\n")
  defp slice_lines(lines, max_lines, :tail), do: lines |> Enum.take(-max_lines) |> Enum.join("\n")

  # Logical lines: a single trailing newline terminates the last line instead
  # of opening a phantom empty one ("a\nb\n" is 2 lines, not 3 — matching what
  # the model sees and avoiding truncated:true on byte-identical output).
  defp split_lines(""), do: [""]

  defp split_lines(content) do
    case :binary.last(content) do
      ?\n -> content |> binary_part(0, byte_size(content) - 1) |> String.split("\n")
      _ -> String.split(content, "\n")
    end
  end

  # Clamp on a UTF-8 boundary by trimming whole characters until under budget.
  defp clamp_bytes(text, max_bytes, side) do
    sliced =
      case side do
        :head -> binary_part(text, 0, max_bytes)
        :tail -> binary_part(text, byte_size(text) - max_bytes, max_bytes)
      end

    # binary_part can split a multibyte char; drop invalid bytes at the cut edge.
    case side do
      :head -> trim_invalid_trailing(sliced)
      :tail -> trim_invalid_leading(sliced)
    end
  end

  defp trim_invalid_trailing(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_invalid_trailing(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  defp trim_invalid_leading(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_invalid_leading(binary_part(bin, 1, byte_size(bin) - 1))
    end
  end
end
