defmodule Catalyst.Auth.OpenAICodexFlow do
  @moduledoc "Authentication lifecycle for the ChatGPT Codex subscription."

  @behaviour Catalyst.Auth.Flow

  alias Catalyst.Auth.OpenAIOAuth

  @impl true
  defdelegate provider_id(), to: OpenAIOAuth

  @impl true
  def label, do: "ChatGPT"

  @impl true
  def login(opts), do: Catalyst.Auth.login_openai_codex(opts)

  @impl true
  def refresh(%{"refresh" => token}) when is_binary(token) and token != "",
    do: OpenAIOAuth.refresh(token)

  def refresh(_credentials), do: {:error, {:missing_refresh_token, provider_id()}}
end
