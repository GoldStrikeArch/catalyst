defmodule CatalystWeb.UI.Markdown do
  @moduledoc """
  A small, safe Markdown-ish parser for chat messages.

  It intentionally returns a simple AST that is rendered by HEEx instead of
  converting Markdown directly to raw HTML. That keeps model/user-provided
  content escaped while still supporting the common formatting assistant replies
  use: paragraphs, headings, lists, blockquotes, fenced code, inline code,
  bold text, and links.
  """

  @type inline ::
          {:text, String.t()}
          | {:code, String.t()}
          | {:strong, [inline()]}
          | {:link, [inline()], String.t()}

  @type block ::
          {:paragraph, [inline()]}
          | {:heading, 1..6, [inline()]}
          | {:ul, [[inline()]]}
          | {:ol, [[inline()]]}
          | {:blockquote, [block()]}
          | {:code, String.t() | nil, String.t()}
          | :hr

  @fence_open ~r/^\s*```\s*([\w.+#-]*)\s*$/
  @fence_close ~r/^\s*```\s*$/
  @heading ~r/^\s{0,3}(\#{1,6})\s+(.+?)\s*#*\s*$/
  @ul_item ~r/^\s{0,3}[-*+]\s+(.+)$/
  @ol_item ~r/^\s{0,3}\d+[.)]\s+(.+)$/
  @blockquote ~r/^\s{0,3}>\s?(.*)$/
  @hr ~r/^\s{0,3}([-*_])(?:\s*\1){2,}\s*$/

  @inline_patterns [
    {:code, ~r/`([^`\n]+)`/},
    {:link, ~r/\[([^\]\n]+)\]\(([^\s)]+)\)/},
    {:strong, ~r/\*\*([^*\n]+)\*\*/},
    {:strong, ~r/__([^_\n]+)__/}
  ]

  @doc "Parse text into a small safe-renderable AST."
  @spec parse(String.t()) :: [block()]
  def parse(text) when is_binary(text) do
    text
    |> normalize_newlines()
    |> String.split("\n", trim: false)
    |> parse_blocks([])
    |> Enum.reverse()
  end

  @doc "True when a link destination is safe to place in an href attribute."
  @spec safe_href?(String.t()) :: boolean()
  def safe_href?(href) when is_binary(href) do
    uri = URI.parse(href)

    cond do
      uri.scheme in ["http", "https", "mailto"] -> true
      String.starts_with?(href, ["/", "#"]) -> true
      true -> false
    end
  rescue
    _ -> false
  end

  def safe_href?(_href), do: false

  defp normalize_newlines(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp parse_blocks([], acc), do: acc

  defp parse_blocks([line | rest], acc) do
    cond do
      blank?(line) ->
        parse_blocks(rest, acc)

      fenced_code?(line) ->
        {block, rest} = take_fenced_code(line, rest)
        parse_blocks(rest, [block | acc])

      heading?(line) ->
        parse_blocks(rest, [heading_block(line) | acc])

      hr?(line) ->
        parse_blocks(rest, [:hr | acc])

      blockquote?(line) ->
        {block, rest} = take_blockquote([line | rest])
        parse_blocks(rest, [block | acc])

      ul_item?(line) ->
        {block, rest} = take_list([line | rest], :ul)
        parse_blocks(rest, [block | acc])

      ol_item?(line) ->
        {block, rest} = take_list([line | rest], :ol)
        parse_blocks(rest, [block | acc])

      true ->
        {block, rest} = take_paragraph([line | rest])
        parse_blocks(rest, [block | acc])
    end
  end

  defp take_fenced_code(opening_line, lines) do
    lang = @fence_open |> Regex.run(opening_line) |> List.last() |> blank_to_nil()
    {code_lines, rest} = Enum.split_while(lines, &(not Regex.match?(@fence_close, &1)))

    rest =
      case rest do
        [_closing | rest] -> rest
        [] -> []
      end

    {{:code, lang, Enum.join(code_lines, "\n")}, rest}
  end

  defp take_blockquote(lines) do
    {quote_lines, rest} = Enum.split_while(lines, &blockquote?/1)

    inner_text =
      quote_lines
      |> Enum.map(fn line -> @blockquote |> Regex.run(line) |> List.last() end)
      |> Enum.join("\n")

    {{:blockquote, parse(inner_text)}, rest}
  end

  defp take_list(lines, kind) do
    {item_lines, rest} = Enum.split_while(lines, &list_item?(&1, kind))

    items =
      Enum.map(item_lines, fn line ->
        line
        |> list_item_text(kind)
        |> parse_inlines()
      end)

    {{kind, items}, rest}
  end

  defp take_paragraph(lines) do
    {paragraph_lines, rest} = Enum.split_while(lines, &(not blank?(&1) and not block_start?(&1)))

    text =
      paragraph_lines
      |> Enum.map(&String.trim/1)
      |> Enum.join(" ")

    {{:paragraph, parse_inlines(text)}, rest}
  end

  defp heading_block(line) do
    [_, markers, text] = Regex.run(@heading, line)
    {:heading, String.length(markers), parse_inlines(text)}
  end

  defp parse_inlines(text), do: do_parse_inlines(text, []) |> Enum.reverse()

  defp do_parse_inlines("", acc), do: acc

  defp do_parse_inlines(text, acc) do
    case next_inline_match(text) do
      nil ->
        [{:text, text} | acc]

      %{start: 0, length: length, kind: kind, captures: captures} ->
        segment = inline_segment(kind, captures)
        rest = binary_part(text, length, byte_size(text) - length)
        do_parse_inlines(rest, [segment | acc])

      %{start: start} ->
        prefix = binary_part(text, 0, start)
        rest = binary_part(text, start, byte_size(text) - start)
        do_parse_inlines(rest, [{:text, prefix} | acc])
    end
  end

  defp next_inline_match(text) do
    @inline_patterns
    |> Enum.with_index()
    |> Enum.flat_map(fn {{kind, regex}, priority} ->
      case Regex.run(regex, text, return: :index) do
        [{start, length} | capture_indexes] ->
          captures = Enum.map(capture_indexes, &capture(text, &1))
          [%{start: start, length: length, kind: kind, captures: captures, priority: priority}]

        nil ->
          []
      end
    end)
    |> Enum.min_by(&{&1.start, &1.priority}, fn -> nil end)
  end

  defp inline_segment(:code, [code]), do: {:code, code}

  defp inline_segment(:strong, [text]), do: {:strong, parse_inlines(text)}

  defp inline_segment(:link, [label, href]), do: {:link, parse_inlines(label), href}

  defp capture(_text, {-1, 0}), do: ""
  defp capture(text, {start, length}), do: binary_part(text, start, length)

  defp block_start?(line) do
    fenced_code?(line) or heading?(line) or hr?(line) or blockquote?(line) or ul_item?(line) or
      ol_item?(line)
  end

  defp fenced_code?(line), do: Regex.match?(@fence_open, line)
  defp heading?(line), do: Regex.match?(@heading, line)
  defp ul_item?(line), do: Regex.match?(@ul_item, line)
  defp ol_item?(line), do: Regex.match?(@ol_item, line)
  defp blockquote?(line), do: Regex.match?(@blockquote, line)
  defp hr?(line), do: Regex.match?(@hr, line)
  defp blank?(line), do: String.trim(line) == ""

  defp list_item?(line, :ul), do: ul_item?(line)
  defp list_item?(line, :ol), do: ol_item?(line)

  defp list_item_text(line, :ul), do: @ul_item |> Regex.run(line) |> List.last()
  defp list_item_text(line, :ol), do: @ol_item |> Regex.run(line) |> List.last()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
