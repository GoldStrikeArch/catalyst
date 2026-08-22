defmodule Catalyst.Auth.GrokFlow do
  @moduledoc "Authentication lifecycle for the SuperGrok subscription."

  @behaviour Catalyst.Auth.Flow

  alias Catalyst.Auth.XAIOAuth

  @impl true
  defdelegate provider_id(), to: XAIOAuth

  @impl true
  def label, do: "SuperGrok"

  @impl true
  def login(opts), do: Catalyst.Auth.login_grok(opts)

  @impl true
  def refresh(credentials) when is_map(credentials), do: XAIOAuth.refresh(credentials)
end
