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

  defp truncate(content, opts, side) do
    max_lines = Keyword.get(opts, :max_lines, @default_max_lines)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    lines = String.split(content, "\n")
    total_lines = length(lines)
    total_bytes = byte_size(content)

    {kept_lines, by_lines?} =
      if total_lines > max_lines do
        sliced =
          case side do
            :head -> Enum.take(lines, max_lines)
            :tail -> Enum.take(lines, -max_lines)
          end

        {sliced, true}
      else
        {lines, false}
      end

    text = Enum.join(kept_lines, "\n")

    {text, by_bytes?} =
      if byte_size(text) > max_bytes do
        {clamp_bytes(text, max_bytes, side), true}
      else
        {text, false}
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
       output_lines: length(String.split(text, "\n")),
       total_bytes: total_bytes
     }}
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
