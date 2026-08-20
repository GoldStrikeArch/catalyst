defmodule Catalyst.ACP.Supervisor do
  @moduledoc """
  Supervises one persistent ACP client per Catalyst session and configured agent.
  """

  use Supervisor

  alias Catalyst.ACP.{Agent, Client}

  @registry Catalyst.ACP.Registry
  @clients Catalyst.ACP.ClientSupervisor

  @doc "Start the ACP supervision tree."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Fetch or start the client for one Catalyst session/agent pair."
  @spec client(String.t(), Agent.t(), Path.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def client(session_id, %Agent{} = agent, cwd, opts \\ []) do
    key = {session_id, agent.id}

    case Registry.lookup(@registry, key) do
      [{pid, _value}] ->
        matching_client(pid, Keyword.get(opts, :resume_id))

      [] ->
        case DynamicSupervisor.start_child(
               @clients,
               {Client, [session_id: session_id, agent: agent, cwd: cwd] ++ opts}
             ) do
          {:error, {:already_started, pid}} ->
            matching_client(pid, Keyword.get(opts, :resume_id))

          other ->
            other
        end
    end
  end

  defp matching_client(pid, nil), do: {:ok, pid}

  defp matching_client(pid, expected_session_id) do
    case Client.info(pid) do
      %{session_id: ^expected_session_id} ->
        {:ok, pid}

      %{session_id: actual_session_id} ->
        {:error, {:acp_session_mismatch, expected_session_id, actual_session_id}}
    end
  catch
    :exit, reason -> {:error, {:acp_client_unavailable, reason}}
  end

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: @registry},
        {DynamicSupervisor, name: @clients, strategy: :one_for_one}
      ],
      strategy: :one_for_all
    )
  end
end
