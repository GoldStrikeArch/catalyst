defmodule CatalystWeb.ProviderBoundaryTest do
  use ExUnit.Case, async: true

  @forbidden ~r/\b(?:OpenAIOAuth|XAIOAuth|OpenAICodexFlow|GrokFlow|OpenAICodex|GrokSubscription|openai-codex(?:-responses)?|xai-grok)\b/

  test "generic web source does not own concrete providers or authentication flows" do
    sources =
      __DIR__
      |> Path.join("../../lib")
      |> Path.expand()
      |> Path.join("**/*.{ex,heex}")
      |> Path.wildcard()

    assert sources != []

    violations =
      for source <- sources,
          contents = File.read!(source),
          Regex.match?(@forbidden, contents),
          do: Path.relative_to_cwd(source)

    assert violations == []
  end
end
