defmodule Catalyst.Runtime.Generations do
  @moduledoc """
  Serialized lifecycle coordinator for managed API-v2 generations.

  Candidate construction, process startup, and health checks run outside the
  coordinator process. Only a completely staged candidate is atomically
  published. Failed staging leaves the prior generation untouched.
  """

  use GenServer

  require Logger

  alias Catalyst.Extension.Manifest

  alias Catalyst.Runtime.{
    Candidate,
    CandidateProcesses,
    CandidateStager,
    Generation,
    GenerationStore
  }

  alias Catalyst.Tasks

  @default_call_timeout 120_000

  @type owner_manifests :: %{optional(String.t()) => [Manifest.t()]}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Install or replace one source owner's manifests and activate the full composition."
  @spec install(String.t(), [Manifest.t()]) :: {:ok, Generation.t()} | {:error, term()}
  def install(owner, manifests) when is_binary(owner) and is_list(manifests) do
    GenServer.call(__MODULE__, {:install, owner, manifests}, call_timeout())
  end

  @doc "Replace the complete managed owner composition in one activation."
  @spec replace_all(owner_manifests()) :: {:ok, Generation.t() | nil} | {:error, term()}
  def replace_all(owners) when is_map(owners) do
    GenServer.call(__MODULE__, {:replace_all, owners}, call_timeout())
  end

  @doc "Remove one source owner from the managed composition."
  @spec remove_owner(String.t()) :: :ok | {:error, term()}
  def remove_owner(owner) when is_binary(owner) do
    case GenServer.call(__MODULE__, {:remove_owner, owner}, call_timeout()) do
      {:ok, _generation} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Remove owners absent from the enabled extension-file set."
  @spec reconcile(MapSet.t(String.t())) :: :ok | {:error, term()}
  def reconcile(%MapSet{} = live_owners) do
    case GenServer.call(__MODULE__, {:reconcile, live_owners}, call_timeout()) do
      {:ok, _generation} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Fail closed by removing every managed generation and process."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear, call_timeout())

  @doc "Return the currently active generation."
  @spec active() :: Generation.t() | nil
  def active, do: GenerationStore.active()

  @doc "List retained active, retired, and rejected generation records."
  @spec list() :: [Generation.t()]
  def list, do: GenerationStore.list()

  @impl true
  def init(:ok) do
    CandidateProcesses.stop_all()
    GenerationStore.clear()
    {:ok, %{operation: nil, active_monitor: nil}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    state = cancel_operation(state)
    state = demonitor_active(state)
    CandidateProcesses.stop_all()
    GenerationStore.clear()
    {:reply, :ok, state}
  end

  def handle_call(request, from, %{operation: nil} = state) do
    case proposed_owners(request, GenerationStore.owners()) do
      :noop ->
        {:reply, {:ok, GenerationStore.active()}, state}

      {:ok, owners} ->
        start_operation(from, owners, state)
    end
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :generation_activation_in_progress}, state}

  @impl true
  def handle_info({reference, result}, %{operation: %{task: %{ref: reference}}} = state) do
    Process.demonitor(reference, [:flush])
    state = finish_operation(result, state.operation, state)
    {:noreply, %{state | operation: nil}}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, reason},
        %{operation: %{task: %{ref: reference}}} = state
      ) do
    GenServer.reply(state.operation.from, {:error, {:candidate_staging_exit, reason}})
    {:noreply, %{state | operation: nil}}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, reason},
        %{active_monitor: %{ref: reference, generation_id: generation_id}} = state
      ) do
    Logger.error("active runtime generation process subtree exited",
      generation: inspect(generation_id),
      reason: inspect(reason)
    )

    GenerationStore.deactivate(generation_id, {:candidate_process_exit, reason})
    {:noreply, %{state | active_monitor: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp proposed_owners({:install, owner, []}, owners) do
    case Map.has_key?(owners, owner) do
      true -> {:ok, Map.delete(owners, owner)}
      false -> :noop
    end
  end

  defp proposed_owners({:install, owner, manifests}, owners) do
    case Map.get(owners, owner) == manifests do
      true -> :noop
      false -> {:ok, Map.put(owners, owner, manifests)}
    end
  end

  defp proposed_owners({:remove_owner, owner}, owners) do
    case Map.has_key?(owners, owner) do
      true -> {:ok, Map.delete(owners, owner)}
      false -> :noop
    end
  end

  defp proposed_owners({:replace_all, owners}, current) do
    case owners == current do
      true -> :noop
      false -> {:ok, owners}
    end
  end

  defp proposed_owners({:reconcile, live_owners}, owners) do
    proposed_owners({:replace_all, Map.take(owners, MapSet.to_list(live_owners))}, owners)
  end

  defp start_operation(from, owners, state) do
    parent = GenerationStore.active_id()
    task = Tasks.async(fn -> CandidateStager.stage(owners, parent) end)
    operation = %{from: from, owners: owners, parent: parent, task: task}
    {:noreply, %{state | operation: operation}}
  end

  defp finish_operation({:ok, candidate, supervisor, mode}, operation, state) do
    case {GenerationStore.active_id() == operation.parent, Process.alive?(supervisor)} do
      {true, true} ->
        activate_candidate(candidate, supervisor, mode, operation, state)

      {false, _alive?} ->
        CandidateProcesses.stop(supervisor)
        GenServer.reply(operation.from, {:error, :stale_candidate_parent})
        state

      {true, false} ->
        reason = :candidate_processes_exited_before_activation
        CandidateProcesses.stop(supervisor)
        GenerationStore.reject(candidate, operation.owners, reason)
        GenServer.reply(operation.from, {:error, reason})
        state
    end
  end

  defp finish_operation({:error, reason, %Candidate{} = candidate}, operation, state) do
    GenerationStore.reject(candidate, operation.owners, reason)
    GenServer.reply(operation.from, {:error, reason})
    state
  end

  defp finish_operation({:error, reason}, operation, state) do
    GenServer.reply(operation.from, {:error, reason})
    state
  end

  defp activate_candidate(candidate, supervisor, mode, operation, state) do
    old_id = GenerationStore.active_id()
    {:ok, generation, _previous} = GenerationStore.publish(candidate, operation.owners)
    state = monitor_active(state, generation.id, supervisor)
    stop_superseded(old_id, candidate.id, supervisor, mode)
    GenServer.reply(operation.from, {:ok, generation})
    state
  end

  defp stop_superseded(nil, _new_id, _supervisor, _mode), do: :ok

  defp stop_superseded(old_id, new_id, _supervisor, _mode) do
    case old_id == new_id do
      true -> :ok
      false -> Tasks.start_background(fn -> CandidateProcesses.stop(old_id) end)
    end
  end

  defp monitor_active(state, generation_id, supervisor) do
    state = demonitor_active(state)
    monitor = %{ref: Process.monitor(supervisor), generation_id: generation_id, pid: supervisor}
    %{state | active_monitor: monitor}
  end

  defp demonitor_active(%{active_monitor: nil} = state), do: state

  defp demonitor_active(%{active_monitor: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    %{state | active_monitor: nil}
  end

  defp cancel_operation(%{operation: nil} = state), do: state

  defp cancel_operation(%{operation: operation} = state) do
    Task.shutdown(operation.task, :brutal_kill)
    Process.demonitor(operation.task.ref, [:flush])
    GenServer.reply(operation.from, {:error, :generation_activation_cancelled})
    %{state | operation: nil}
  end

  defp call_timeout do
    Application.get_env(:catalyst, :runtime_generation_call_timeout, @default_call_timeout)
  end
end
