defmodule Catalyst.Session.Manager do
  @moduledoc """
  Starts and looks up sessions. Each session is a `Catalyst.Session.Server`
  started under a `DynamicSupervisor` and registered by id in a `Registry`.
  """

  @registry Catalyst.Session.Registry
  @dynamic_supervisor Catalyst.Session.DynamicSupervisor
  @valid_id ~r/\A[A-Za-z0-9_-]+\z/

  @doc """
  Start a new session. Options are forwarded to `Catalyst.Session.Server`
  (`:cwd`, `:system_prompt`, `:model`, `:provider`, `:tools`, `:opts`); an `:id`
  is generated if not supplied. Returns `{:ok, %{id, pid}}`.
  """
  @spec start_session(keyword()) ::
          {:ok, %{id: String.t(), pid: pid()}} | {:error, term()}
  def start_session(opts \\ []) do
    id = Keyword.get(opts, :id) || gen_id()

    case valid_id?(id) do
      true -> start_validated(id, Keyword.put(opts, :id, id))
      false -> {:error, {:invalid_session_id, id}}
    end
  end

  @doc "`:via` tuple for registering/addressing a session by id."
  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(id), do: {:via, Registry, {@registry, id}}

  @doc "Pid for a session id, or `:error` when no session is registered."
  @spec whereis(String.t()) :: {:ok, pid()} | :error
  def whereis(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Terminate a session."
  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(id) do
    case whereis(id) do
      :error -> :ok
      {:ok, pid} -> DynamicSupervisor.terminate_child(@dynamic_supervisor, pid)
    end
  end

  defp start_validated(id, opts) do
    case DynamicSupervisor.start_child(@dynamic_supervisor, {Catalyst.Session.Server, opts}) do
      {:ok, pid} -> {:ok, %{id: id, pid: pid}}
      {:error, {:already_started, pid}} -> {:ok, %{id: id, pid: pid}}
      other -> other
    end
  end

  defp valid_id?(id) when is_binary(id), do: Regex.match?(@valid_id, id)
  defp valid_id?(_id), do: false

  defp gen_id, do: Catalyst.Ids.hex(8)
end
