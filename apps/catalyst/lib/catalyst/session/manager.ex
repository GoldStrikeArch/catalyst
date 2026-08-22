defmodule Catalyst.Session.Manager do
  @moduledoc """
  Starts and looks up sessions. Each session is a `Catalyst.Session.Server`
  child spec selected by the managed-local session factory, started under a
  `DynamicSupervisor`, and registered by id in a `Registry`.
  """

  @registry Catalyst.Session.Registry
  @dynamic_supervisor Catalyst.Session.DynamicSupervisor
  @valid_id ~r/\A[A-Za-z0-9_-]+\z/

  alias Catalyst.Runtime.SessionFactory

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

  @doc """
  Start a genuinely fresh session for a child agent.

  Unlike `start_session/1`, this never adopts an already-running process and
  asks the store for exclusive create-new semantics, so an on-disk transcript
  is a collision rather than an implicit resume.
  """
  @spec start_unique_session(keyword()) ::
          {:ok, %{id: String.t(), pid: pid()}} | {:error, term()}
  def start_unique_session(opts) when is_list(opts) do
    id = Keyword.get(opts, :id) || gen_unique_id()

    cond do
      not valid_id?(id) ->
        {:error, {:invalid_session_id, id}}

      match?({:ok, _pid}, whereis(id)) ->
        {:error, {:session_id_collision, id}}

      true ->
        start_unique_validated(id, opts)
    end
  end

  @doc "`:via` tuple for registering/addressing a session by id."
  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(id), do: {:via, Registry, {@registry, id}}

  @doc "Live pid for a session id, or `:error` when no live session is registered."
  @spec whereis(String.t()) :: {:ok, pid()} | :error
  def whereis(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> live_pid(pid)
      [] -> :error
    end
  end

  @doc "Currently registered live sessions as `{id, pid}` pairs."
  @spec list_live() :: [{String.t(), pid()}]
  def list_live do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_id, pid} -> Process.alive?(pid) end)
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
    start_with_factory(id, opts, :resume)
  end

  defp start_unique_validated(id, opts) do
    child_opts =
      opts
      |> Keyword.put(:id, id)
      |> Keyword.put(:create, :exclusive)

    start_with_factory(id, child_opts, :exclusive)
  end

  defp start_with_factory(id, opts, mode) do
    case SessionFactory.resolve_and_pin([session_id: id], self()) do
      {:ok, factory} -> start_with_factory(id, opts, mode, factory)
      {:error, _reason} = error -> error
    end
  end

  defp start_with_factory(id, opts, mode, factory) do
    case SessionFactory.child_spec(factory, opts) do
      {:ok, child_spec} ->
        @dynamic_supervisor
        |> DynamicSupervisor.start_child(child_spec)
        |> finish_start(id, factory, mode)

      {:error, _reason} = error ->
        :ok = SessionFactory.release(factory)
        error
    end
  end

  defp finish_start({:ok, pid}, id, _factory, _mode), do: {:ok, %{id: id, pid: pid}}

  defp finish_start({:error, {:already_started, pid}}, id, factory, :resume) do
    :ok = SessionFactory.release(factory)
    {:ok, %{id: id, pid: pid}}
  end

  defp finish_start({:error, {:already_started, _pid}}, id, factory, :exclusive) do
    :ok = SessionFactory.release(factory)
    {:error, {:session_id_collision, id}}
  end

  defp finish_start({:error, {:shutdown, {:session_exists, id}}}, id, factory, :exclusive) do
    :ok = SessionFactory.release(factory)
    {:error, {:session_exists, id}}
  end

  defp finish_start({:error, {:session_exists, id}}, id, factory, :exclusive) do
    :ok = SessionFactory.release(factory)
    {:error, {:session_exists, id}}
  end

  defp finish_start(result, _id, factory, _mode) do
    :ok = SessionFactory.release(factory)
    result
  end

  defp valid_id?(id) when is_binary(id), do: Regex.match?(@valid_id, id)
  defp valid_id?(_id), do: false

  # Registry removes entries asynchronously after an owner exits. Do not leak
  # that short-lived tombstone through the manager's lookup contract.
  defp live_pid(pid) do
    case Process.alive?(pid) do
      true -> {:ok, pid}
      false -> :error
    end
  end

  defp gen_id, do: Catalyst.Ids.hex(8)
  defp gen_unique_id, do: Catalyst.Ids.hex(16)
end
