defmodule Catalyst.Session.Manager do
  @moduledoc """
  Starts and looks up sessions. Each session is a `Catalyst.Session.Server`
  started under a `DynamicSupervisor` and registered by id in a `Registry`.
  """

  @registry Catalyst.Session.Registry
  @dynamic_supervisor Catalyst.Session.DynamicSupervisor

  @doc """
  Start a new session. Options are forwarded to `Catalyst.Session.Server`
  (`:cwd`, `:system_prompt`, `:model`, `:provider`, `:tools`, `:opts`); an `:id`
  is generated if not supplied. Returns `{:ok, %{id, pid}}`.
  """
  def start_session(opts \\ []) do
    id = Keyword.get(opts, :id) || gen_id()
    opts = Keyword.put(opts, :id, id)

    case DynamicSupervisor.start_child(@dynamic_supervisor, {Catalyst.Session.Server, opts}) do
      {:ok, pid} -> {:ok, %{id: id, pid: pid}}
      {:error, {:already_started, pid}} -> {:ok, %{id: id, pid: pid}}
      other -> other
    end
  end

  @doc "`:via` tuple for registering/addressing a session by id."
  def via(id), do: {:via, Registry, {@registry, id}}

  @doc "Pid for a session id, or nil."
  def whereis(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Terminate a session."
  def stop(id) do
    case whereis(id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@dynamic_supervisor, pid)
    end
  end

  defp gen_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
