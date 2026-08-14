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
    # A poisoned runtime seam must not spend the DynamicSupervisor's shared
    # restart budget and take unrelated sessions down with it. The transcript
    # remains durable, so callers can explicitly resume this id after the
    # underlying fault is fixed instead of automatically restart-looping it.
    child_spec =
      Supervisor.child_spec({Catalyst.Session.Server, opts}, restart: :temporary)

    case DynamicSupervisor.start_child(@dynamic_supervisor, child_spec) do
      {:ok, pid} -> {:ok, %{id: id, pid: pid}}
      {:error, {:already_started, pid}} -> {:ok, %{id: id, pid: pid}}
      other -> other
    end
  end

  defp start_unique_validated(id, opts) do
    child_opts =
      opts
      |> Keyword.put(:id, id)
      |> Keyword.put(:create, :exclusive)

    # `:temporary`: a crashed exclusive child must not be supervisor-restarted —
    # the retained `create: :exclusive` opt would hit its own JSONL (`:eexist`),
    # fail every restart, and exhaust the shared supervisor's intensity, killing
    # every live session. spawn_agent monitors the child and reports the crash.
    child_spec =
      Supervisor.child_spec({Catalyst.Session.Server, child_opts}, restart: :temporary)

    case DynamicSupervisor.start_child(@dynamic_supervisor, child_spec) do
      {:ok, pid} -> {:ok, %{id: id, pid: pid}}
      {:error, {:already_started, _pid}} -> {:error, {:session_id_collision, id}}
      {:error, {:shutdown, {:session_exists, ^id}}} -> {:error, {:session_exists, id}}
      {:error, {:session_exists, ^id}} -> {:error, {:session_exists, id}}
      other -> other
    end
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
