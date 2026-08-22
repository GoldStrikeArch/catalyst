defmodule Catalyst.Test.RuntimeProcessPolicy do
  @moduledoc false

  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner, name: __MODULE__)

  @impl true
  def init(owner), do: {:ok, owner}

  @impl true
  def handle_call(
        {:catalyst_runtime, :permission_policy_v1, :authorize, arguments},
        _from,
        owner
      ) do
    send(owner, {:process_policy_request, arguments})
    {:reply, :allow, owner}
  end
end
