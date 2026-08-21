defmodule Catalyst.Runtime.Leases do
  @moduledoc """
  Monitored process ownership for managed runtime-generation leases.

  Lease acquisition is authorized by `Catalyst.Runtime.Generations`, which
  serializes it with active-generation switches. This process owns monitors and
  guarantees cleanup when a lease owner exits.
  """

  use GenServer

  alias Catalyst.Runtime.{GenerationId, Lease}

  @type snapshot_result :: {:ok, [Lease.t()]} | {:error, term()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec acquire(GenerationId.t(), pid(), Lease.binding()) ::
          {:ok, Lease.t()} | {:error, term()}
  def acquire(%GenerationId{} = generation, owner, binding)
      when is_pid(owner) and is_atom(binding) do
    GenServer.call(__MODULE__, {:acquire, generation, owner, binding})
  end

  @doc "Release a lease. Releasing an already removed lease is harmless."
  @spec release(Lease.t() | reference()) :: :ok
  def release(%Lease{ref: ref}), do: release(ref)

  def release(ref) when is_reference(ref) do
    GenServer.call(__MODULE__, {:release, ref})
  catch
    :exit, _reason -> :ok
  end

  @doc "List active leases in stable acquisition order."
  @spec list() :: [Lease.t()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Capture active leases without crashing an introspection caller during recovery."
  @spec snapshot() :: snapshot_result()
  def snapshot do
    {:ok, list()}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Count active leases for one generation."
  @spec count(GenerationId.t()) :: non_neg_integer()
  def count(%GenerationId{} = generation),
    do: GenServer.call(__MODULE__, {:count, generation})

  @doc false
  @spec revoke_generation(GenerationId.t()) :: :ok
  def revoke_generation(%GenerationId{} = generation),
    do: GenServer.call(__MODULE__, {:revoke_generation, generation})

  @doc false
  @spec revoke_all() :: :ok
  def revoke_all, do: GenServer.call(__MODULE__, :revoke_all)

  @impl true
  def init(:ok), do: {:ok, empty_state()}

  @impl true
  def handle_call({:acquire, generation, owner, binding}, _from, state) do
    case Process.alive?(owner) do
      true ->
        lease = %Lease{
          ref: make_ref(),
          generation: generation,
          owner: owner,
          binding: binding,
          acquired_at: DateTime.utc_now()
        }

        {:reply, {:ok, lease}, put_lease(state, lease)}

      false ->
        {:reply, {:error, :lease_owner_not_alive}, state}
    end
  end

  def handle_call({:release, ref}, _from, state) do
    {state, generations} = drop_refs(state, [ref])
    notify_drained(generations, state)
    {:reply, :ok, state}
  end

  def handle_call(:list, _from, state) do
    leases =
      state.leases
      |> Map.values()
      |> Enum.sort_by(& &1.acquired_at, DateTime)

    {:reply, leases, state}
  end

  def handle_call({:count, generation}, _from, state),
    do: {:reply, generation_count(state, generation), state}

  def handle_call({:revoke_generation, generation}, _from, state) do
    refs =
      state.leases
      |> Enum.flat_map(fn
        {ref, %Lease{generation: ^generation}} -> [ref]
        _entry -> []
      end)

    {state, _generations} = drop_refs(state, refs)
    {:reply, :ok, state}
  end

  def handle_call(:revoke_all, _from, state) do
    Enum.each(state.monitors, fn {monitor, _owner} ->
      Process.demonitor(monitor, [:flush])
    end)

    {:reply, :ok, empty_state()}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {^owner, monitors} ->
        refs = Map.get(state.owners, owner, MapSet.new()) |> MapSet.to_list()
        state = %{state | monitors: monitors}
        {state, generations} = drop_refs(state, refs)
        notify_drained(generations, state)
        {:noreply, state}

      {nil, _monitors} ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp empty_state, do: %{leases: %{}, owners: %{}, owner_monitors: %{}, monitors: %{}}

  defp put_lease(state, lease) do
    {state, monitor} = ensure_owner_monitor(state, lease.owner)
    refs = state.owners |> Map.get(lease.owner, MapSet.new()) |> MapSet.put(lease.ref)

    %{
      state
      | leases: Map.put(state.leases, lease.ref, lease),
        owners: Map.put(state.owners, lease.owner, refs),
        owner_monitors: Map.put(state.owner_monitors, lease.owner, monitor)
    }
  end

  defp ensure_owner_monitor(state, owner) do
    case Map.fetch(state.owner_monitors, owner) do
      {:ok, monitor} ->
        {state, monitor}

      :error ->
        monitor = Process.monitor(owner)
        {%{state | monitors: Map.put(state.monitors, monitor, owner)}, monitor}
    end
  end

  defp drop_refs(state, refs) do
    Enum.reduce(refs, {state, MapSet.new()}, fn ref, {current, generations} ->
      case Map.pop(current.leases, ref) do
        {nil, _leases} ->
          {current, generations}

        {%Lease{} = lease, leases} ->
          current = %{current | leases: leases}
          current = drop_owner_ref(current, lease.owner, ref)
          {current, MapSet.put(generations, lease.generation)}
      end
    end)
  end

  defp drop_owner_ref(state, owner, ref) do
    refs = state.owners |> Map.fetch!(owner) |> MapSet.delete(ref)

    case MapSet.size(refs) do
      0 ->
        {monitor, owner_monitors} = Map.pop(state.owner_monitors, owner)
        Process.demonitor(monitor, [:flush])

        %{
          state
          | owners: Map.delete(state.owners, owner),
            owner_monitors: owner_monitors,
            monitors: Map.delete(state.monitors, monitor)
        }

      _count ->
        %{state | owners: Map.put(state.owners, owner, refs)}
    end
  end

  defp notify_drained(generations, state) do
    Enum.each(generations, fn generation ->
      case generation_count(state, generation) do
        0 -> notify_generation_drained(generation)
        _count -> :ok
      end
    end)
  end

  defp notify_generation_drained(generation) do
    case Process.whereis(Catalyst.Runtime.Generations) do
      nil -> :ok
      pid -> send(pid, {:generation_drained, generation})
    end
  end

  defp generation_count(state, generation) do
    Enum.count(state.leases, fn {_ref, lease} -> lease.generation == generation end)
  end
end
