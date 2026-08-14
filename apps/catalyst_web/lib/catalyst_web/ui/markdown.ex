defmodule CatalystWeb.UI.Markdown do
  @moduledoc """
  A small, safe Markdown-ish parser for chat messages.

  It intentionally returns a simple AST that is rendered by HEEx instead of
  converting Markdown directly to raw HTML. That keeps model/user-provided
  content escaped while still supporting the common formatting assistant replies
  use: paragraphs, headings, lists, blockquotes, fenced code, inline code,
  bold, italic, and links. Soft line breaks inside a paragraph stay as
  line breaks.
  """

  @type inline ::
          {:text, String.t()}
          | {:code, String.t()}
          | {:strong, [inline()]}
          | {:em, [inline()]}
          | {:br}
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
    {:strong, ~r/__([^_\n]+)__/},
    {:em, ~r/\*([^*\n]+)\*/},
    {:em, ~r/_([^_\n]+)_/}
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

  @doc """
  Split streaming text into `{stable_blocks, tail_source}` for progressive
  rendering.

  Every block except the last is STABLE: block classification is line-anchored,
  so once a new block has started after it, no appended text can reinterpret
  it — the stable prefix of a longer text is always an extension of the stable
  prefix of a shorter one, and converges to `parse/1` of the full text.

  Two safeguards make that invariant hold:

    * **Newline gating** (the Codex CLI's rule): only complete
      (newline-terminated) lines participate in parsing. A half-received
      `---` would otherwise briefly parse as an `hr`, prematurely
      stabilizing the paragraph before it, and then merge back INTO that
      paragraph when the line continues (`---anything` is paragraph text).
    * **The last block always stays in the tail** (it may still absorb
      lines), with one refinement: a trailing fence-CLOSED code block is
      committed immediately — nothing can merge backward into it, and it's
      the block that benefits most from prompt rendering (highlighting).

  The tail is raw SOURCE (last block + any partial line), suited for a plain
  live-append display; `stable_blocks ++ parse(tail_source)` == `parse(text)`.
  """
  @spec stable_split(String.t()) :: {[block()], String.t()}
  def stable_split(text) when is_binary(text) do
    lines = text |> normalize_newlines() |> String.split("\n", trim: false)
    {complete, [partial]} = Enum.split(lines, length(lines) - 1)

    {stable_rev, tail_lines} = do_stable_split(complete, [])
    {Enum.reverse(stable_rev), Enum.join(tail_lines ++ [partial], "\n")}
  end

  defp do_stable_split(lines, acc) do
    case Enum.drop_while(lines, &blank?/1) do
      [] ->
        # Nothing but blanks left — they belong to the (empty) tail.
        {acc, lines}

      remaining ->
        {block, rest} = take_one_block(remaining)
        consumed = Enum.take(remaining, length(remaining) - length(rest))

        cond do
          # A later block has started — this one can no longer change.
          Enum.any?(rest, &(not blank?(&1))) ->
            do_stable_split(rest, [block | acc])

          trailing_closed_code?(block, consumed) ->
            {[block | acc], rest}

          true ->
            # Last block: keep it (and its leading blanks) as the tail.
            {acc, lines}
        end
    end
  end

  # A last-position code block whose fence actually closed is final: any later
  # line starts a NEW block (even another ``` opens a fresh fence). Checked on
  # the lines the block CONSUMED (trailing blanks already sit in `rest`).
  defp trailing_closed_code?({:code, _lang, _body}, consumed) when length(consumed) >= 2,
    do: Regex.match?(@fence_close, List.last(consumed))

  defp trailing_closed_code?(_block, _consumed), do: false

  @doc "True when a link destination is safe to place in an href attribute."
  @spec safe_href?(String.t()) :: boolean()
  def safe_href?(href) when is_binary(href) do
    uri = URI.parse(href)

    cond do
      uri.scheme in ["http", "https", "mailto"] -> true
      # A single leading `/` is a local path; `//host` is protocol-relative
      # (scheme nil, but it navigates to an arbitrary external host).
      String.starts_with?(href, "/") -> not String.starts_with?(href, "//")
      String.starts_with?(href, "#") -> true
      true -> false
    end
  rescue
    _ -> false
  end

  def safe_href?(_href), do: false

  @doc """
  Split a `stable_split/1` tail into `{preview_blocks, raw_partial}`.

  Complete (newline-terminated) lines are parsed so the still-open last
  block paints as markdown instead of source. The unfinished last line
  stays raw — it has not been newline-gated yet.

      iex> {blocks, raw} = CatalystWeb.UI.Markdown.preview_tail("- one\\n- two")
      iex> blocks
      [{:ul, [[{:text, "one"}]]}]
      iex> raw
      "- two"
  """
  @spec preview_tail(String.t()) :: {[block()], String.t()}
  def preview_tail(tail) when is_binary(tail) do
    lines = tail |> normalize_newlines() |> String.split("\n", trim: false)
    {complete, [partial]} = Enum.split(lines, length(lines) - 1)

    case Enum.any?(complete, &(not blank?(&1))) do
      false ->
        {[], tail}

      true ->
        {parse(Enum.join(complete, "\n")), partial}
    end
  end

  defp normalize_newlines(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp parse_blocks(lines, acc) do
    case Enum.drop_while(lines, &blank?/1) do
      [] ->
        acc

      remaining ->
        {block, rest} = take_one_block(remaining)
        parse_blocks(rest, [block | acc])
    end
  end

  # `lines` starts with a non-blank line; consume exactly one block.
  defp take_one_block([line | rest] = lines) do
    cond do
      fenced_code?(line) -> take_fenced_code(line, rest)
      heading?(line) -> {heading_block(line), rest}
      hr?(line) -> {:hr, rest}
      blockquote?(line) -> take_blockquote(lines)
      ul_item?(line) -> take_list(lines, :ul)
      ol_item?(line) -> take_list(lines, :ol)
      true -> take_paragraph(lines)
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
      Enum.map_join(quote_lines, "\n", fn line ->
        @blockquote |> Regex.run(line) |> List.last()
      end)

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

    inlines =
      paragraph_lines
      |> Enum.map(&(&1 |> String.trim() |> parse_inlines()))
      |> Enum.intersperse([{:br}])
      |> List.flatten()

    {{:paragraph, inlines}, rest}
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

  defp inline_segment(:em, [text]), do: {:em, parse_inlines(text)}

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
