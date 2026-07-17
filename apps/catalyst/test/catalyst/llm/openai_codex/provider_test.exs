defmodule Catalyst.LLM.OpenAICodex.ProviderTest do
  use ExUnit.Case, async: false

  alias Catalyst.LLM.Context
  alias Catalyst.LLM.OpenAICodex
  alias Catalyst.Message

  test "returns an error assistant (never raises) when not authenticated" do
    model = OpenAICodex.model("gpt-5.4")
    context = %Context{system_prompt: "x", messages: [Message.user("hi")], tools: []}

    assert {:ok, assistant} = OpenAICodex.Provider.stream(model, context, [], fn _ -> :ok end)
    assert assistant.stop_reason == :error
    assert assistant.error_message =~ "not authenticated"
    assert assistant.api == "openai-codex-responses"
  end

  test "the api is registered to the Codex provider" do
    assert {:ok, OpenAICodex.Provider} = Catalyst.LLM.Registry.fetch("openai-codex-responses")
  end
end
