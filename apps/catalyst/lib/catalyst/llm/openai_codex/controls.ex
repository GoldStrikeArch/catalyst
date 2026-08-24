defmodule Catalyst.LLM.OpenAICodex.Controls do
  @moduledoc "Model-picker and authentication controls for the bundled Codex provider."

  @behaviour Catalyst.LLM.Controls

  alias Catalyst.Auth.OpenAIOAuth
  alias Catalyst.LLM.OpenAICodex

  @impl true
  def id, do: "openai-codex"

  @impl true
  defdelegate default_model_id(), to: OpenAICodex

  @impl true
  defdelegate list_models(), to: OpenAICodex

  @impl true
  defdelegate catalog_entry(id), to: OpenAICodex

  @impl true
  defdelegate model(id), to: OpenAICodex

  @impl true
  defdelegate default_effort(), to: OpenAICodex

  @impl true
  def auth_provider, do: OpenAIOAuth.provider_id()

  @impl true
  def auth_label, do: "ChatGPT"

  @impl true
  def run_opts(prefs) do
    [
      reasoning_effort: prefs.effort,
      service_tier: service_tier(prefs.fast),
      transport: prefs.transport
    ]
  end

  defp service_tier(true), do: "priority"
  defp service_tier(false), do: nil
end
