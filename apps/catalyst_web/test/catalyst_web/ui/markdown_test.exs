defmodule CatalystWeb.UI.MarkdownTest do
  use ExUnit.Case, async: true

  alias CatalystWeb.UI.Markdown

  # A corpus exercising every supported construct, including the hazards:
  # an hr directly after a paragraph (the newline-gating case) and a fence
  # whose body contains block-looking lines.
  @corpus [
    """
    # Title

    Intro paragraph
    spanning two lines.

    - item one
    - item two

    ```elixir
    def foo, do: :ok
    # not a heading
    - not a list
    ```

    After the code block.

    ---

    > quoted text
    > more quote

    1. first
    2. second
    """,
    "para text\n---\nafter the rule\n",
    "no trailing newline at all",
    "```unclosed\ncode that never ends\nstill code",
    "**bold** then `code` then [link](https://example.com)\n\n## Sub\ndone\n"
  ]

  describe "stable_split/1" do
    test "commits are monotone under char-by-char growth and converge to parse/1" do
      for full <- @corpus do
        final = Markdown.parse(full)

        committed =
          Enum.reduce(1..String.length(full), [], fn i, prev ->
            prefix = String.slice(full, 0, i)
            {blocks, tail} = Markdown.stable_split(prefix)

            # Monotone: earlier commits are a prefix of later ones — nothing
            # already shown to the user is ever reinterpreted.
            assert Enum.take(blocks, length(prev)) == prev,
                   "prefix #{inspect(prefix)} destabilized earlier commits"

            # Lossless: stable blocks + parsed tail == full parse of prefix.
            assert blocks ++ Markdown.parse(tail) == Markdown.parse(prefix),
                   "prefix #{inspect(prefix)} lost content between blocks and tail"

            blocks
          end)

        assert Enum.take(final, length(committed)) == committed
      end
    end

    test "a half-received line never participates (newline gating)" do
      # "---" without its newline could be an hr — or the start of "---anything",
      # which would merge into the paragraph. It must stay in the tail.
      {blocks, tail} = Markdown.stable_split("para text\n---")
      assert blocks == []
      assert tail == "para text\n---"

      # Once the line completes as an hr, the paragraph is stable.
      {blocks, _tail} = Markdown.stable_split("para text\n---\n")
      assert blocks == [{:paragraph, [{:text, "para text"}]}]
    end

    test "an open fence stays in the tail; a closed trailing fence commits" do
      {blocks, tail} = Markdown.stable_split("```elixir\ndef f, do: :ok\n")
      assert blocks == []
      assert tail == "```elixir\ndef f, do: :ok\n"

      {blocks, tail} = Markdown.stable_split("```elixir\ndef f, do: :ok\n```\n")
      assert blocks == [{:code, "elixir", "def f, do: :ok"}]
      assert tail == ""
    end

    test "the last non-code block always stays in the tail" do
      {blocks, tail} = Markdown.stable_split("- one\n- two\n")
      assert blocks == []
      assert tail == "- one\n- two\n"

      # A following paragraph stabilizes the list.
      {blocks, tail} = Markdown.stable_split("- one\n- two\n\nnext\n")
      assert blocks == [{:ul, [[{:text, "one"}], [{:text, "two"}]]}]
      assert tail =~ "next"
    end

    test "empty and blank-only input" do
      assert Markdown.stable_split("") == {[], ""}
      assert Markdown.stable_split("\n\n") == {[], "\n\n"}
    end
  end

  test "emphasis does not steal a bold span" do
    assert Markdown.parse("**bold** and *italic* and _also_") ==
             [
               {:paragraph,
                [
                  {:strong, [{:text, "bold"}]},
                  {:text, " and "},
                  {:em, [{:text, "italic"}]},
                  {:text, " and "},
                  {:em, [{:text, "also"}]}
                ]}
             ]
  end

  test "soft breaks inside a paragraph stay as line breaks" do
    assert Markdown.parse("Intro paragraph\nspanning two lines.") ==
             [
               {:paragraph, [{:text, "Intro paragraph"}, {:br}, {:text, "spanning two lines."}]}
             ]
  end

  describe "preview_tail/1" do
    test "parses complete tail lines and leaves the unfinished line raw" do
      assert Markdown.preview_tail("- one\n- two") ==
               {[{:ul, [[{:text, "one"}]]}], "- two"}

      assert Markdown.preview_tail("- one\n- two\n") ==
               {[{:ul, [[{:text, "one"}], [{:text, "two"}]]}], ""}

      assert Markdown.preview_tail("closing thoughts") == {[], "closing thoughts"}
    end

    test "does not parse a half-received hr line as a rule" do
      assert Markdown.preview_tail("para text\n---") ==
               {[{:paragraph, [{:text, "para text"}]}], "---"}
    end
  end
end
