defmodule Catalyst.Runtime.CandidateProcesses do
  @moduledoc """
  Process staging for managed runtime candidates.

  Every candidate receives a temporary `DynamicSupervisor`. Failed candidates
  are killed as a unit; an activated candidate remains alive until a later
  generation replaces it. Process declarations are started with a bounded wait.
  """

  alias Catalyst.Runtime.{Candidate, GenerationId}
  alias Catalyst.Tasks

  @registry Catalyst.Runtime.CandidateProcessRegistry
  @top Catalyst.Runtime.CandidateProcessSupervisor
  @default_start_timeout 5_000
  @stale_retry_ms 5
  @stale_retries 10

  @doc "Start and fully populate a candidate-owned process subtree."
  @spec start(Candidate.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Candidate{} = candidate) do
    with {:ok, supervisor} <- start_supervisor(candidate.id, @stale_retries) do
      case start_declarations(supervisor, candidate.processes, []) do
        :ok ->
          {:ok, supervisor}

        {:error, reason, children} ->
          stop_known(supervisor, children)
          {:error, reason}
      end
    end
  end

  @doc "Whether the process subtree for `id` is currently alive."
  @spec alive?(GenerationId.t()) :: boolean()
  def alive?(%GenerationId{} = id) do
    case lookup(id) do
      {:ok, pid} -> Process.alive?(pid)
      :error -> false
    end
  end

  @doc "Return direct children of the candidate process subtree."
  @spec list(GenerationId.t()) :: [pid()]
  def list(%GenerationId{} = id) do
    case lookup(id) do
      {:ok, supervisor} -> safe_children(supervisor)
      :error -> []
    end
  end

  @doc "Brutally stop one candidate subtree without trusting child shutdown values."
  @spec stop(GenerationId.t() | pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(%GenerationId{} = id) do
    case lookup(id) do
      {:ok, pid} -> stop(pid)
      :error -> :ok
    end
  end

  def stop(pid) when is_pid(pid) do
    children = safe_children(pid)
    Process.exit(pid, :kill)
    Enum.each(children, &Process.exit(&1, :kill))
    :ok
  end

  @doc false
  @spec stop_all() :: :ok
  def stop_all do
    case Process.whereis(@top) do
      nil ->
        :ok

      top ->
        top
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn {_id, pid, _type, _modules} -> stop(pid) end)
    end
  end

  defp start_supervisor(id, retries) do
    name = {:via, Registry, {@registry, GenerationId.to_wire(id)}}

    spec = %{
      id: {:candidate, GenerationId.to_wire(id)},
      start: {DynamicSupervisor, :start_link, [[name: name, strategy: :one_for_one]]},
      restart: :temporary,
      type: :supervisor
    }

    case DynamicSupervisor.start_child(@top, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} when retries > 0 ->
        existing_or_retry(id, pid, retries)

      {:error, {:already_started, pid}} ->
        case Process.alive?(pid) do
          true -> {:ok, pid}
          false -> {:error, :stale_candidate_process_registry}
        end

      {:error, reason} ->
        {:error, {:candidate_supervisor_start_failed, reason}}
    end
  end

  defp existing_or_retry(id, pid, retries) do
    case Process.alive?(pid) do
      true ->
        {:ok, pid}

      false ->
        Process.sleep(@stale_retry_ms)
        start_supervisor(id, retries - 1)
    end
  end

  defp start_declarations(supervisor, declarations, children) do
    Enum.reduce_while(declarations, {:ok, children}, fn declaration, {:ok, started} ->
      case start_declaration(supervisor, declaration) do
        {:ok, pid} -> {:cont, {:ok, [pid | started]}}
        {:error, reason} -> {:halt, {:error, reason, started}}
      end
    end)
    |> case do
      {:ok, _children} -> :ok
      {:error, _reason, _children} = error -> error
    end
  end

  defp start_declaration(supervisor, declaration) do
    task =
      Tasks.async(fn -> DynamicSupervisor.start_child(supervisor, declaration.child_spec) end)

    case Tasks.await(task, start_timeout()) do
      {:ok, {:ok, pid}} ->
        {:ok, pid}

      {:ok, {:ok, pid, _info}} ->
        {:ok, pid}

      {:ok, {:error, reason}} ->
        {:error, {:candidate_process_start_failed, declaration.id, reason}}

      {:exit, reason} ->
        {:error, {:candidate_process_start_exit, declaration.id, reason}}

      :timeout ->
        {:error, {:candidate_process_start_timeout, declaration.id}}
    end
  end

  defp lookup(id) do
    case Registry.lookup(@registry, GenerationId.to_wire(id)) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp safe_children(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, _type, _modules} when is_pid(pid) -> [pid]
      _child -> []
    end)
  catch
    :exit, _reason -> []
  end

  defp stop_known(supervisor, children) do
    Process.exit(supervisor, :kill)
    Enum.each(children, &Process.exit(&1, :kill))
    :ok
  end

  defp start_timeout do
    Application.get_env(
      :catalyst,
      :runtime_candidate_process_start_timeout,
      @default_start_timeout
    )
  end
end
