defmodule Catalyst.Context.Transcript do
  @moduledoc """
  Structural rules for chronological request transcripts.

  A transcript is a list of `Catalyst.Message` structs where every assistant
  tool call is immediately followed by exactly its complete result set. This
  module owns validation and unit grouping of that shape so persistence replay
  (`Catalyst.Session.Store`) and context policies share one definition without
  the store depending on a hot-swappable policy module.
  """

  alias Catalyst.Message

  @doc "Validate the tool-call grouping invariants of a chronological transcript."
  @spec validate_transcript([Message.t()]) :: :ok | {:error, term()}
  def validate_transcript(messages) when is_list(messages) do
    with :ok <- validate_messages(messages) do
      validate_groups(messages)
    end
  end

  def validate_transcript(other), do: {:error, {:invalid_transcript, other}}

  @doc "True when a chronological list is a structurally valid request transcript."
  @spec valid_transcript?([Message.t()]) :: boolean()
  def valid_transcript?(messages), do: validate_transcript(messages) == :ok

  @doc """
  Group a transcript into indivisible units.

  Each assistant tool-call message and its complete immediately-following
  result set is one unit; ordinary messages are single-message units.
  """
  @spec message_units([Message.t()]) :: [[Message.t()]]
  def message_units(messages), do: messages |> do_units([]) |> Enum.reverse()

  @doc "Length of the longest exactly-equal message suffix shared by two transcripts."
  @spec common_suffix_length([Message.t()], [Message.t()]) :: non_neg_integer()
  def common_suffix_length(original, replacement),
    do: do_common_suffix(Enum.reverse(original), Enum.reverse(replacement), 0)

  defp do_common_suffix([message | original], [message | replacement], count),
    do: do_common_suffix(original, replacement, count + 1)

  defp do_common_suffix(_original, _replacement, count), do: count

  defp do_units([], acc), do: acc

  defp do_units([%Message.Assistant{} = assistant | rest], acc) do
    case Message.tool_calls(assistant) do
      [] ->
        do_units(rest, [[assistant] | acc])

      _calls ->
        {results, tail} = Enum.split_while(rest, &match?(%Message.ToolResult{}, &1))
        do_units(tail, [[assistant | results] | acc])
    end
  end

  defp do_units([message | rest], acc), do: do_units(rest, [[message] | acc])

  defp validate_messages(messages) do
    case Enum.find(messages, &(not message?(&1))) do
      nil -> :ok
      invalid -> {:error, {:invalid_transcript_message, invalid}}
    end
  end

  defp message?(%Message.User{}), do: true
  defp message?(%Message.Assistant{}), do: true
  defp message?(%Message.ToolResult{}), do: true
  defp message?(_other), do: false

  defp validate_groups([]), do: :ok

  defp validate_groups([%Message.ToolResult{} | _rest]),
    do: {:error, :orphan_tool_result}

  defp validate_groups([%Message.Assistant{} = assistant | rest]) do
    case Message.tool_calls(assistant) do
      [] -> validate_groups(rest)
      calls -> validate_assistant_group(calls, rest)
    end
  end

  defp validate_groups([_message | rest]), do: validate_groups(rest)

  defp validate_assistant_group(calls, rest) do
    {results, tail} = Enum.split_while(rest, &match?(%Message.ToolResult{}, &1))
    expected = calls |> Enum.map(& &1.id) |> MapSet.new()
    actual = results |> Enum.map(& &1.tool_call_id) |> MapSet.new()

    case expected == actual and length(calls) == MapSet.size(expected) and
           length(results) == MapSet.size(actual) do
      true -> validate_groups(tail)
      false -> {:error, {:invalid_tool_result_group, expected, actual}}
    end
  end
end
