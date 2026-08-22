defmodule Catalyst.Runtime.Generations do
  @moduledoc """
  Serialized lifecycle coordinator for managed API-v2 generations.

  Candidate construction, process startup, and health checks run outside the
  coordinator process. Only a completely staged candidate is atomically
  published. Failed staging leaves the prior generation untouched. A retained
  parent is restored only when the active candidate process root exits during
  its bounded post-activation stabilization window.
  """

  use GenServer

  require Logger

  alias Catalyst.Extension.Manifest

  alias Catalyst.Runtime.{
    ActivationId,
    Artifacts,
    Candidate,
    CandidateProcesses,
    CandidateStager,
    Generation,
    GenerationStore,
    Leases,
    Resolution,
    RetirementPolicy
  }

  alias Catalyst.Tasks

  @default_call_timeout 120_000
  @default_stabilization_ms 10_000

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

  @doc """
  Explicitly terminate lease owners blocking retirement of a failed or retiring generation.

  The generation remains retained until owner monitors confirm that every lease
  has drained. Active generations cannot be force-retired.
  """
  @spec force_retire(ActivationId.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def force_retire(%ActivationId{} = generation_id) do
    GenServer.call(__MODULE__, {:force_retire, generation_id}, call_timeout())
  end

  @doc false
  @spec acquire_lease(Resolution.t(), pid()) ::
          {:ok, Catalyst.Runtime.Lease.t() | nil} | {:error, term()}
  def acquire_lease(%Resolution{} = resolution, owner \\ self()) when is_pid(owner) do
    GenServer.call(__MODULE__, {:acquire_lease, resolution, owner}, call_timeout())
  end

  @doc "Return the currently active generation."
  @spec active() :: Generation.t() | nil
  def active do
    case GenerationStore.active() do
      %Generation{} = generation -> with_lease_count(generation, Leases.snapshot())
      nil -> nil
    end
  end

  @doc "List retained active, retired, and rejected generation records."
  @spec list() :: [Generation.t()]
  def list, do: list(Leases.snapshot())

  @doc false
  @spec list(Leases.snapshot_result()) :: [Generation.t()]
  def list(lease_snapshot) do
    Enum.map(GenerationStore.list(), &with_lease_count(&1, lease_snapshot))
  end

  @impl true
  def init(:ok) do
    CandidateProcesses.stop_all()
    release_unleased_artifacts()
    GenerationStore.clear()
    {:ok, empty_state()}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    state = cancel_operation(state)
    state = cancel_cleanups(state)
    state = demonitor_all(state)
    state = cancel_drain_timers(state)
    state = cancel_stabilizations(state)
    CandidateProcesses.stop_all()
    release_unleased_artifacts()
    GenerationStore.clear()
    {:reply, :ok, state}
  end

  def handle_call({:force_retire, generation_id}, _from, state) do
    case GenerationStore.fetch(generation_id) do
      {:ok, %Generation{status: status}} when status in [:retiring, :failed] ->
        {result, state} = force_retirement(generation_id, state)
        {:reply, result, state}

      {:ok, %Generation{status: :active}} ->
        {:reply, {:error, :active_generation}, state}

      {:ok, %Generation{status: status}} ->
        {:reply, {:error, {:generation_not_retiring, status}}, state}

      :error ->
        {:reply, {:error, :unknown_generation}, state}
    end
  end

  def handle_call({:acquire_lease, resolution, owner}, _from, state) do
    {:reply, acquire_active_lease(resolution, owner), state}
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
    cleanup_operation_artifacts(state.operation)
    GenServer.reply(state.operation.from, {:error, {:candidate_staging_exit, reason}})
    {:noreply, %{state | operation: nil}}
  end

  def handle_info({reference, result}, state) when is_reference(reference) do
    case Map.pop(state.cleanups, reference) do
      {nil, _cleanups} ->
        {:noreply, state}

      {cleanup, cleanups} ->
        Process.demonitor(reference, [:flush])
        state = drop_cleanup(state, cleanup.generation_id, cleanups)
        {:noreply, finish_retirement_cleanup(cleanup.generation_id, result, state)}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    case Map.pop(state.cleanups, reference) do
      {nil, _cleanups} ->
        handle_generation_down(reference, reason, state)

      {cleanup, cleanups} ->
        state = drop_cleanup(state, cleanup.generation_id, cleanups)
        {:noreply, retry_retirement_cleanup(cleanup.generation_id, reason, state)}
    end
  end

  def handle_info({:generation_drained, generation_id}, state) do
    {:noreply, retire_if_drained(generation_id, state)}
  end

  def handle_info({:generation_drain_timeout, generation_id}, state) do
    state = drop_drain_timer(state, generation_id)

    case Leases.count(generation_id) do
      0 ->
        {:noreply, retire_if_drained(generation_id, state)}

      count ->
        GenerationStore.mark_drain_timeout(generation_id, DateTime.utc_now())

        case RetirementPolicy.current().on_timeout do
          :retain ->
            Logger.warning("runtime generation exceeded its drain deadline",
              generation: ActivationId.to_wire(generation_id),
              lease_count: count
            )

            {:noreply, state}

          :cancel_owners ->
            {_result, state} = force_retirement(generation_id, state)
            {:noreply, state}
        end
    end
  end

  def handle_info({:generation_cleanup_retry, generation_id}, state) do
    {:noreply, retire_if_drained(generation_id, state)}
  end

  def handle_info({:generation_stabilized, generation_id, parent_id}, state) do
    case pop_stabilization(state, generation_id, parent_id) do
      {:ok, state} -> {:noreply, retire_or_schedule(parent_id, state)}
      :error -> {:noreply, state}
    end
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
    activation_id = ActivationId.new()
    artifact_ids = Artifacts.referenced_ids(Map.values(owners))
    task = Tasks.async(fn -> CandidateStager.stage(owners, parent, activation_id) end)

    operation = %{
      from: from,
      owners: owners,
      parent: parent,
      activation_id: activation_id,
      artifact_ids: artifact_ids,
      task: task
    }

    {:noreply, %{state | operation: operation}}
  end

  defp finish_operation({:ok, candidate, supervisor, mode}, operation, state) do
    case {GenerationStore.active_id() == operation.parent, Process.alive?(supervisor)} do
      {true, true} ->
        activate_candidate(candidate, supervisor, mode, operation, state)

      {false, _alive?} ->
        CandidateProcesses.stop(supervisor)
        cleanup_operation_artifacts(operation)
        GenServer.reply(operation.from, {:error, :stale_candidate_parent})
        state

      {true, false} ->
        reason = :candidate_processes_exited_before_activation
        CandidateProcesses.stop(supervisor)
        cleanup_operation_artifacts(operation)
        GenerationStore.reject(candidate, operation.owners, reason)
        GenServer.reply(operation.from, {:error, reason})
        state
    end
  end

  defp finish_operation({:error, reason, %Candidate{} = candidate}, operation, state) do
    cleanup_operation_artifacts(operation)
    GenerationStore.reject(candidate, operation.owners, reason)
    GenServer.reply(operation.from, {:error, reason})
    state
  end

  defp finish_operation({:error, reason}, operation, state) do
    cleanup_operation_artifacts(operation)
    GenServer.reply(operation.from, {:error, reason})
    state
  end

  defp activate_candidate(candidate, supervisor, mode, operation, state) do
    old_id = GenerationStore.active_id()
    {:ok, generation, _previous} = GenerationStore.publish(candidate, operation.owners)
    state = monitor_generation(state, generation.id, supervisor)
    state = retain_superseded(old_id, generation.id, mode, state)
    GenServer.reply(operation.from, {:ok, generation})
    state
  end

  defp retain_superseded(nil, _new_id, _mode, state), do: state

  defp retain_superseded(old_id, new_id, _mode, state) do
    case {old_id == new_id, stabilization_ms()} do
      {true, _timeout} -> state
      {false, 0} -> retire_or_schedule(old_id, state)
      {false, timeout} -> put_stabilization(state, new_id, old_id, timeout)
    end
  end

  defp retire_or_schedule(generation_id, state) do
    case stabilization_parent?(state, generation_id) do
      true -> state
      false -> generation_id |> retire_if_drained(state) |> schedule_drain_timeout(generation_id)
    end
  end

  defp stabilization_parent?(state, generation_id) do
    Enum.any?(state.stabilizations, fn {_child, entry} ->
      entry.parent_id == generation_id
    end)
  end

  defp retire_if_drained(%ActivationId{} = generation_id, state) do
    case {GenerationStore.fetch(generation_id), Leases.count(generation_id)} do
      {{:ok, %Generation{status: status}}, 0} when status in [:retiring, :failed] ->
        begin_retirement_cleanup(generation_id, state)

      {:error, 0} ->
        Artifacts.release_activation(generation_id)
        state

      _not_ready ->
        state
    end
  end

  defp acquire_active_lease(%Resolution{} = resolution, owner) do
    case Map.get(resolution.claim.metadata, :runtime_generation) do
      nil ->
        {:ok, nil}

      requested ->
        case GenerationStore.active_id() do
          %ActivationId{} = active ->
            acquire_matching_lease(active, requested, resolution.binding, owner)

          nil ->
            {:error, {:stale_runtime_generation, requested, nil}}
        end
    end
  end

  defp acquire_matching_lease(active, requested, binding, owner) do
    case ActivationId.to_wire(active) == requested do
      true -> Leases.acquire(active, owner, binding_lifetime(binding))
      false -> {:error, {:stale_runtime_generation, requested, ActivationId.to_wire(active)}}
    end
  end

  defp binding_lifetime({:pin, lifetime}), do: lifetime
  defp binding_lifetime(:live), do: :live

  defp monitor_generation(state, generation_id, supervisor) do
    monitor = Process.monitor(supervisor)
    entry = %{generation_id: generation_id, pid: supervisor}
    %{state | monitors: Map.put(state.monitors, monitor, entry)}
  end

  defp demonitor_generation(state, generation_id) do
    {removed, retained} =
      Enum.split_with(state.monitors, fn {_reference, entry} ->
        entry.generation_id == generation_id
      end)

    Enum.each(removed, fn {reference, _entry} ->
      Process.demonitor(reference, [:flush])
    end)

    %{state | monitors: Map.new(retained)}
  end

  defp demonitor_all(state) do
    Enum.each(state.monitors, fn {reference, _entry} ->
      Process.demonitor(reference, [:flush])
    end)

    %{state | monitors: %{}}
  end

  defp handle_generation_down(reference, reason, state) do
    case Map.pop(state.monitors, reference) do
      {nil, _monitors} ->
        {:noreply, state}

      {%{generation_id: generation_id}, monitors} ->
        state = %{state | monitors: monitors}
        {:noreply, handle_generation_exit(generation_id, reason, state)}
    end
  end

  defp handle_generation_exit(generation_id, reason, state) do
    active? = GenerationStore.active_id() == generation_id

    case active? do
      true ->
        Logger.error("active runtime generation process subtree exited",
          generation: inspect(generation_id),
          reason: inspect(reason)
        )

      false ->
        :ok
    end

    case take_stabilization(state, generation_id) do
      {%{} = stabilization, state} when active? ->
        rollback_or_fail(generation_id, stabilization.parent_id, reason, state)

      {%{} = stabilization, state} ->
        GenerationStore.fail(generation_id, {:candidate_process_exit, reason})

        state = retire_or_schedule(generation_id, state)
        retire_or_schedule(stabilization.parent_id, state)

      {nil, state} ->
        GenerationStore.fail(generation_id, {:candidate_process_exit, reason})
        retire_or_schedule(generation_id, state)
    end
  end

  defp rollback_or_fail(generation_id, parent_id, reason, state) do
    rollback_reason =
      {:candidate_process_exit, reason, {:rolled_back_to, ActivationId.to_wire(parent_id)}}

    with true <- CandidateProcesses.alive?(parent_id),
         {:ok, _parent} <- GenerationStore.rollback(generation_id, parent_id, rollback_reason) do
      Logger.warning("rolled back unstable runtime generation after process subtree exit",
        generation: ActivationId.to_wire(generation_id),
        parent: ActivationId.to_wire(parent_id),
        reason: inspect(reason)
      )

      state = cancel_drain_timer(state, parent_id)
      retire_or_schedule(generation_id, state)
    else
      _not_safe ->
        GenerationStore.fail(generation_id, {:candidate_process_exit, reason})

        state = retire_or_schedule(generation_id, state)
        retire_or_schedule(parent_id, state)
    end
  end

  defp put_stabilization(state, generation_id, parent_id, timeout) do
    timer =
      Process.send_after(
        self(),
        {:generation_stabilized, generation_id, parent_id},
        timeout
      )

    entry = %{parent_id: parent_id, timer: timer}
    key = ActivationId.to_wire(generation_id)
    %{state | stabilizations: Map.put(state.stabilizations, key, entry)}
  end

  defp take_stabilization(state, generation_id) do
    key = ActivationId.to_wire(generation_id)

    case Map.pop(state.stabilizations, key) do
      {nil, _stabilizations} ->
        {nil, state}

      {entry, stabilizations} ->
        Process.cancel_timer(entry.timer)
        {entry, %{state | stabilizations: stabilizations}}
    end
  end

  defp pop_stabilization(state, generation_id, parent_id) do
    key = ActivationId.to_wire(generation_id)

    case Map.get(state.stabilizations, key) do
      %{parent_id: ^parent_id} ->
        {:ok, %{state | stabilizations: Map.delete(state.stabilizations, key)}}

      _missing_or_stale ->
        :error
    end
  end

  defp cancel_stabilizations(state) do
    Enum.each(state.stabilizations, fn {_generation, entry} ->
      Process.cancel_timer(entry.timer)
    end)

    %{state | stabilizations: %{}}
  end

  defp schedule_drain_timeout(state, generation_id) do
    timeout = RetirementPolicy.current().drain_timeout

    case {timeout, GenerationStore.fetch(generation_id), Leases.count(generation_id)} do
      {:infinity, _generation, _leases} ->
        state

      {_timeout, {:ok, %Generation{status: status}}, 0}
      when status in [:retiring, :failed] ->
        state

      {timeout, {:ok, %Generation{status: status}}, leases}
      when status in [:retiring, :failed] and leases > 0 ->
        cancel_drain_timer(state, generation_id)
        |> put_drain_timer(generation_id, timeout)

      _not_retiring ->
        state
    end
  end

  defp put_drain_timer(state, generation_id, timeout) do
    timer = Process.send_after(self(), {:generation_drain_timeout, generation_id}, timeout)
    %{state | drain_timers: Map.put(state.drain_timers, generation_id, timer)}
  end

  defp cancel_drain_timer(state, generation_id) do
    case Map.pop(state.drain_timers, generation_id) do
      {nil, _timers} ->
        state

      {timer, timers} ->
        Process.cancel_timer(timer)
        %{state | drain_timers: timers}
    end
  end

  defp drop_drain_timer(state, generation_id),
    do: %{state | drain_timers: Map.delete(state.drain_timers, generation_id)}

  defp cancel_drain_timers(state) do
    Enum.each(state.drain_timers, fn {_generation_id, timer} -> Process.cancel_timer(timer) end)
    %{state | drain_timers: %{}}
  end

  defp force_retirement(generation_id, state) do
    GenerationStore.mark_forced_retirement(generation_id, DateTime.utc_now())
    state = cancel_drain_timer(state, generation_id)

    case Leases.cancel_generation(generation_id) do
      {:ok, 0} ->
        {{:ok, 0}, retire_if_drained(generation_id, state)}

      {:ok, count} ->
        {{:ok, count}, state}
    end
  end

  defp release_unleased_artifacts do
    case Artifacts.snapshot() do
      {:ok, artifacts} ->
        artifacts
        |> Enum.flat_map(&MapSet.to_list(&1.activations))
        |> Enum.uniq()
        |> Enum.each(&release_if_unleased/1)

      {:error, _reason} ->
        :ok
    end

    Artifacts.clear()
  end

  defp release_if_unleased(activation) do
    case Leases.count(activation) do
      0 -> Artifacts.release_activation(activation)
      _retained -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp cancel_operation(%{operation: nil} = state), do: state

  defp cancel_operation(%{operation: operation} = state) do
    Task.shutdown(operation.task, :brutal_kill)
    Process.demonitor(operation.task.ref, [:flush])
    cleanup_operation_artifacts(operation)
    GenServer.reply(operation.from, {:error, :generation_activation_cancelled})
    %{state | operation: nil}
  end

  defp begin_retirement_cleanup(generation_id, state) do
    key = ActivationId.to_wire(generation_id)

    case Map.has_key?(state.cleanup_generations, key) do
      true ->
        state

      false ->
        state = state |> demonitor_generation(generation_id) |> cancel_drain_timer(generation_id)
        task = Tasks.async(fn -> CandidateProcesses.stop(generation_id) end)
        cleanup = %{generation_id: generation_id, task: task}

        %{
          state
          | cleanups: Map.put(state.cleanups, task.ref, cleanup),
            cleanup_generations: Map.put(state.cleanup_generations, key, task.ref)
        }
    end
  end

  defp finish_retirement_cleanup(generation_id, :ok, state) do
    GenerationStore.retire(generation_id, :drained)
    Artifacts.release_activation(generation_id)
    state
  end

  defp finish_retirement_cleanup(generation_id, result, state) do
    retry_retirement_cleanup(generation_id, result, state)
  end

  defp retry_retirement_cleanup(generation_id, reason, state) do
    Logger.warning("runtime generation cleanup did not complete",
      generation: ActivationId.to_wire(generation_id),
      reason: inspect(reason)
    )

    Process.send_after(self(), {:generation_cleanup_retry, generation_id}, 100)
    state
  end

  defp drop_cleanup(state, generation_id, cleanups) do
    key = ActivationId.to_wire(generation_id)

    %{
      state
      | cleanups: cleanups,
        cleanup_generations: Map.delete(state.cleanup_generations, key)
    }
  end

  defp cancel_cleanups(state) do
    Enum.each(state.cleanups, fn {reference, cleanup} ->
      Process.demonitor(reference, [:flush])
      Task.shutdown(cleanup.task, :brutal_kill)
    end)

    %{state | cleanups: %{}, cleanup_generations: %{}}
  end

  defp cleanup_operation_artifacts(operation) do
    Artifacts.release_activation(operation.activation_id)
    Artifacts.discard(operation.artifact_ids)
  end

  defp with_lease_count(%Generation{} = generation, {:ok, leases}) do
    count = Enum.count(leases, &(&1.generation == generation.id))
    %{generation | lease_count: count}
  end

  defp with_lease_count(%Generation{} = generation, {:error, _reason}),
    do: %{generation | lease_count: :unknown}

  defp call_timeout do
    Application.get_env(:catalyst, :runtime_generation_call_timeout, @default_call_timeout)
  end

  defp empty_state do
    %{
      operation: nil,
      monitors: %{},
      stabilizations: %{},
      drain_timers: %{},
      cleanups: %{},
      cleanup_generations: %{}
    }
  end

  defp stabilization_ms do
    case Application.get_env(
           :catalyst,
           :runtime_generation_stabilization_ms,
           @default_stabilization_ms
         ) do
      timeout when is_integer(timeout) and timeout >= 0 -> timeout
      _invalid -> @default_stabilization_ms
    end
  end
end
