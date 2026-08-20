defmodule CatalystWeb.UI.ToolSummaryTest do
  use ExUnit.Case, async: true

  alias CatalystWeb.UI.ToolSummary

  doctest ToolSummary

  # Argument keys mirror the parameters/0 schemas of Catalyst.Tools.*; a
  # rename there must show up here as a failing row, not as a silent fall
  # through to the JSON fallback.
  @cases [
    {"read", %{"path" => "lib/app.ex", "offset" => 10}, {"Read", "lib/app.ex"}},
    {"write", %{"path" => "lib/new.ex", "content" => "hi"}, {"Write", "lib/new.ex"}},
    {"edit", %{"path" => "lib/app.ex", "edits" => [%{}, %{}]}, {"Edit", "lib/app.ex (2 edits)"}},
    {"edit", %{"path" => "lib/app.ex", "edits" => [%{}]}, {"Edit", "lib/app.ex (1 edit)"}},
    {"edit", %{"path" => "lib/app.ex"}, {"Edit", "lib/app.ex"}},
    {"bash", %{"command" => "mix test"}, {"Bash", "mix test"}},
    {"bash", %{"command" => "cd /tmp\nls -la"}, {"Bash", "cd /tmp"}},
    {"grep", %{"pattern" => "defp", "path" => "lib"}, {"Grep", "defp (lib)"}},
    {"grep", %{"pattern" => "defp"}, {"Grep", "defp"}},
    {"find", %{"pattern" => "*.ex", "path" => "apps"}, {"Find", "*.ex (apps)"}},
    {"ast_grep", %{"pattern" => "def $F", "lang" => "elixir"}, {"Ast grep", "def $F (elixir)"}},
    {"ls", %{"path" => "apps/catalyst"}, {"List", "apps/catalyst"}},
    {"ls", %{}, {"List", "."}},
    {"replace", %{"pattern" => "a", "replacement" => "b", "path" => "f.ex"},
     {"Replace", "a → b in f.ex"}},
    {"fetch", %{"url" => "https://example.com"}, {"Fetch", "https://example.com"}},
    {"shell_session", %{"action" => "write", "chars" => "iex\n"}, {"Shell", "iex"}},
    {"shell_session", %{"action" => "start"}, {"Shell", "start"}},
    {"spawn_agent", %{"agent" => "scout", "task" => "find the bug\nin lib"},
     {"Agent", "find the bug"}},
    {"computer", %{"action" => "screenshot"}, {"Computer", "screenshot"}}
  ]

  for {name, args, expected} <- @cases do
    test "summarizes #{name} #{inspect(args)}" do
      assert ToolSummary.summarize(unquote(Macro.escape(name)), unquote(Macro.escape(args))) ==
               unquote(Macro.escape(expected))
    end
  end

  test "a long detail is truncated with an ellipsis" do
    path = String.duplicate("deep/", 40) <> "file.ex"
    {"Read", detail} = ToolSummary.summarize("read", %{"path" => path})

    assert String.length(detail) == 80
    assert String.ends_with?(detail, "…")
    assert String.starts_with?(path, String.trim_trailing(detail, "…"))
  end

  test "a bash command gets a tighter budget than other details" do
    {"Bash", detail} = ToolSummary.summarize("bash", %{"command" => String.duplicate("x", 200)})

    assert String.length(detail) == 70
    assert String.ends_with?(detail, "…")
  end

  test "an unknown tool falls back to a humanized name and compact JSON" do
    assert ToolSummary.summarize("weather_report", %{"city" => "Kyoto"}) ==
             {"Weather report", ~s({"city":"Kyoto"})}
  end

  test "an unknown tool with no arguments has an empty detail" do
    assert ToolSummary.summarize("list_agents", %{}) == {"List agents", ""}
  end

  test "the fallback JSON detail is capped" do
    {_label, detail} = ToolSummary.summarize("mystery", %{"blob" => String.duplicate("y", 500)})

    assert String.length(detail) == 80
  end

  # A tool call whose arguments have not finished streaming (or whose schema
  # changed) must still summarize instead of raising.
  test "a known tool with unexpected arguments falls back rather than crashing" do
    assert ToolSummary.summarize("read", %{"paht" => "typo.ex"}) ==
             {"Read", ~s({"paht":"typo.ex"})}

    assert ToolSummary.summarize("bash", %{}) == {"Bash", ""}
  end
end
