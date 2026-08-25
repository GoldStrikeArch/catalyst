defmodule Catalyst.LLM.GrokSubscription.Controls do
  @moduledoc "Model-picker and authentication controls for the bundled SuperGrok provider."

  @behaviour Catalyst.LLM.Controls

  alias Catalyst.Auth.XAIOAuth
  alias Catalyst.LLM.GrokSubscription

  @impl true
  def id, do: "grok-subscription"

  @impl true
  defdelegate default_model_id(), to: GrokSubscription

  @impl true
  defdelegate list_models(), to: GrokSubscription

  @impl true
  defdelegate catalog_entry(id), to: GrokSubscription

  @impl true
  defdelegate model(id), to: GrokSubscription

  @impl true
  defdelegate default_effort(), to: GrokSubscription

  @impl true
  def auth_provider, do: XAIOAuth.provider_id()

  @impl true
  def auth_label, do: "SuperGrok"

  @impl true
  def login, do: Catalyst.Auth.XAILogin.login()

  @impl true
  def refresh_auth(creds), do: XAIOAuth.refresh(creds)

  @impl true
  def run_opts(prefs) do
    [reasoning_effort: prefs.effort, service_tier: nil, transport: nil]
  end
end
