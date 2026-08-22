defmodule Catalyst.Session.DefaultSessionFactory do
  @moduledoc """
  Built-in managed-local factory for the existing `Catalyst.Session.Server`.
  """

  @behaviour Catalyst.Contracts.SessionFactory.V1

  @impl true
  def child_spec(opts) when is_list(opts) do
    {:ok, Supervisor.child_spec({Catalyst.Session.Server, opts}, restart: :temporary)}
  end

  def child_spec(opts), do: {:error, {:invalid_session_options, opts}}
end
