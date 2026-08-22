defmodule Catalyst.Test.SessionFactoryA do
  @moduledoc false

  @behaviour Catalyst.Contracts.SessionFactory.V1

  @impl true
  def child_spec(opts) do
    notify(:a)
    Catalyst.Session.DefaultSessionFactory.child_spec(opts)
  end

  defp notify(factory) do
    case :persistent_term.get({__MODULE__, :test_pid}, nil) do
      pid when is_pid(pid) -> send(pid, {:session_factory, factory})
      nil -> :ok
    end
  end
end
