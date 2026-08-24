defmodule Catalyst.BuiltinExtensions.GrokSubscription do
  use Catalyst.Extension

  @impl true
  def metadata do
    %{
      name: "Grok subscription",
      description: "Direct SuperGrok subscription provider bundled with Catalyst"
    }
  end

  @impl true
  def setup(api) do
    Catalyst.ExtensionAPI.register_provider(
      api,
      "grok-subscription-chat-completions",
      Catalyst.LLM.GrokSubscription.Provider
    )
  end
end
