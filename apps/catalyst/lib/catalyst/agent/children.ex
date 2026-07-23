defmodule Catalyst.Agent.Children do
  @moduledoc """
  Owns the live parent/child index and root-tree concurrency leases for subagents.

  A lease is reserved before a child session is created. Reservation and the
  corresponding ETS row are installed by one GenServer call, so concurrent
  branches of the same root tree cannot race past the configured fan-out limit.
  The calling tool task and a cleanup keeper are monitored immediately; the
  child is monitored after `attach/4`. When the keeper differs from the caller,
  caller shutdown leaves capacity reserved until the watchdog completes child
  teardown and exits.

  `Catalyst.Agent.Children.TableOwner` owns the production ETS table, allowing
  this coordinator to rebuild live monitors after its own restart. Releasing a
  lease is idempotent, so explicit cleanup and DOWN messages may safely race.
  Stopping child sessions remains the watchdog's responsibility; this process
  owns accounting and introspection. The one exception: when the keeper itself
  dies while its attached child is still alive, no other process knows about
  the orphan, so the coordinator issues a best-effort `Session.Manager.stop/1`
  and **retains the lease until the child exits** so a replacement reservation
  cannot overbook the root tree.
  """

  use GenServer

  @table :catalyst_agent_children

  @typedoc "Opaque reservation token for one child slot."
  @type lease :: reference()

  @typedoc "One root-tree child row exposed for diagnostics."
  @type entry :: %{
          lease: lease(),
          root_id: String.t(),
          parent_id: String.t(),
          caller: pid(),
          keeper: pid(),
          child_id: String.t() | nil,
          child: pid() | nil
        }

  @type server :: GenServer.server()

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc "Start the child index. Tests may override its registered name and ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      registered -> GenServer.start_link(__MODULE__, opts, name: registered)
    end
  end

  @doc "Reserve one slot, monitoring the caller and optional cleanup `:keeper` process."
  @spec reserve(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, lease()} | {:error, term()}
  def reserve(root_id, parent_id, limit, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    caller = Keyword.get(opts, :caller, self())
    keeper = Keyword.get(opts, :keeper, caller)
    GenServer.call(server, {:reserve, root_id, parent_id, limit, caller, keeper})
  catch
    :exit, reason -> {:error, {:children_unavailable, reason}}
  end

  @doc "Attach the newly-created child session to a reservation."
  @spec attach(lease(), String.t(), pid(), keyword()) :: :ok | {:error, term()}
  def attach(lease, child_id, child, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:attach, lease, child_id, child})
  catch
    :exit, reason -> {:error, {:children_unavailable, reason}}
  end

  # test seam. Releases a reservation; repeated and late releases are
  # successful no-ops.
  @doc false
  @spec release(lease(), keyword()) :: :ok
  def release(lease, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    try do
      GenServer.call(server, {:release, lease})
    catch
      :exit, _reason -> :ok
    end
  end

  # test seam (count/2 also reads it). Lists the current rows for a root tree,
  # in stable parent/child order.
  @doc false
  @spec list(String.t(), keyword()) :: [entry()]
  def list(root_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:list, root_id})
  catch
    :exit, _reason -> []
  end

  @doc "Count active reservations in a root tree."
  @spec count(String.t(), keyword()) :: non_neg_integer()
  def count(root_id, opts \\ []) do
    root_id
    |> list(opts)
    |> length()
  end

  @impl true
  def init(opts) do
    table =
      case Keyword.fetch(opts, :table) do
        # Test path: tests own their table lifecycle, so create on demand.
        {:ok, table} -> ensure_table(table)
        :error -> owned_table!(@table)
      end

    {:ok, recover_state(table)}
  end

  @impl true
  def handle_call({:reserve, root_id, parent_id, limit, caller, keeper}, _from, state) do
    with :ok <- validate_reservation(root_id, parent_id, limit, caller, keeper),
         :ok <- ensure_capacity(state, root_id, limit) do
      lease = make_ref()
      {entry, monitors} = new_entry(lease, root_id, parent_id, caller, keeper)
      :ets.insert(state.table, row(entry))

      state = %{
        state
        | leases: Map.put(state.leases, lease, entry),
          monitors: Map.merge(state.monitors, monitors)
      }

      {:reply, {:ok, lease}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:attach, lease, child_id, child}, _from, state) do
    with :ok <- validate_child(child_id, child),
         {:ok, entry} <- fetch_unattached(state, lease) do
      child_monitor = Process.monitor(child)
      attached = %{entry | child_id: child_id, child: child, child_monitor: child_monitor}

      replace_row(state.table, entry, attached)

      state = %{
        state
        | leases: Map.put(state.leases, lease, attached),
          monitors: Map.put(state.monitors, child_monitor, {lease, :child})
      }

      {:reply, :ok, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:release, lease}, _from, state) do
    {:reply, :ok, drop_lease(state, lease)}
  end

  def handle_call({:list, root_id}, _from, state) do
    entries =
      state.table
      |> :ets.lookup(root_id)
      |> Enum.map(fn {^root_id, entry} -> public_entry(entry) end)
      |> Enum.sort_by(&{&1.parent_id, &1.child_id || "", inspect(&1.lease)})

    {:reply, entries, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, {lease, :caller}} -> {:noreply, detach_caller(state, lease, monitor)}
      {:ok, {lease, :keeper}} -> {:noreply, reap_orphan(state, lease)}
      {:ok, {lease, :child}} -> {:noreply, drop_lease(state, lease)}
      :error -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # `Catalyst.Agent.Children.TableOwner` owns the production table under a
  # `:rest_for_one` supervisor, so it must already exist here; a missing table
  # is an invariant violation and the init crash lets the supervisor restore
  # the correct start order instead of silently adopting a fresh empty table.
  defp owned_table!(table) do
    case :ets.whereis(table) do
      :undefined -> raise "ETS table #{inspect(table)} missing; TableOwner must start first"
      _existing -> table
    end
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [
          :named_table,
          :public,
          :bag,
          read_concurrency: true,
          write_concurrency: true
        ])

      _existing ->
        table
    end
  end

  defp recover_state(table) do
    table
    |> :ets.tab2list()
    |> Enum.reduce(%{table: table, leases: %{}, monitors: %{}}, &recover_row(table, &1, &2))
  end

  defp recover_row(table, {_root_id, entry} = stored, state) when is_map(entry) do
    case recover_entry(entry) do
      {:ok, recovered, monitors} ->
        :ets.delete_object(table, stored)
        :ets.insert(table, row(recovered))

        %{
          state
          | leases: Map.put(state.leases, recovered.lease, recovered),
            monitors: Map.merge(state.monitors, monitors)
        }

      :error ->
        :ets.delete_object(table, stored)
        state
    end
  end

  defp recover_row(table, stored, state) do
    :ets.delete_object(table, stored)
    state
  end

  defp recover_entry(entry) do
    caller = Map.get(entry, :caller)
    keeper = Map.get(entry, :keeper, caller)
    child = Map.get(entry, :child)
    child_id = Map.get(entry, :child_id)

    cond do
      not valid_lease_shape?(entry, caller, keeper) ->
        :error

      recoverable_entry?(entry, caller, keeper, child_id, child) ->
        recovered_entry(entry, caller, keeper, child)

      Process.alive?(keeper) ->
        :error

      true ->
        recover_dead_keeper_entry(entry, child_id, child)
    end
  end

  defp recoverable_entry?(entry, caller, keeper, child_id, child) do
    valid_lease_shape?(entry, caller, keeper) and Process.alive?(keeper) and
      valid_recovered_child?(child_id, child)
  end

  # Dead keeper at recovery mirrors the live reap_orphan/2 policy: a live
  # attached child keeps capacity, is re-monitored, and gets a best-effort
  # stop; a child-id-only row gets the stop attempt but frees capacity; an
  # unattached or dead-child row is dropped so the reservation cannot leak.
  defp recover_dead_keeper_entry(entry, child_id, child)
       when is_binary(child_id) and is_pid(child) do
    case Process.alive?(child) do
      true -> recover_orphan_entry(entry, child)
      false -> :error
    end
  end

  defp recover_dead_keeper_entry(_entry, child_id, _child) when is_binary(child_id) do
    request_child_stop(child_id)
    :error
  end

  defp recover_dead_keeper_entry(_entry, _child_id, _child), do: :error

  defp valid_lease_shape?(entry, caller, keeper) do
    is_reference(Map.get(entry, :lease)) and nonblank?(Map.get(entry, :root_id)) and
      nonblank?(Map.get(entry, :parent_id)) and is_pid(caller) and is_pid(keeper)
  end

  defp valid_recovered_child?(nil, nil), do: true

  defp valid_recovered_child?(child_id, child) when is_pid(child),
    do: nonblank?(child_id) and Process.alive?(child)

  defp valid_recovered_child?(_child_id, _child), do: false

  defp recovered_entry(entry, caller, keeper, child) do
    lease = Map.fetch!(entry, :lease)
    keeper_monitor = Process.monitor(keeper)
    monitors = %{keeper_monitor => {lease, :keeper}}

    {caller_monitor, monitors} =
      recover_caller_monitor(caller, keeper, keeper_monitor, lease, monitors)

    {child_monitor, monitors} = recover_child_monitor(child, lease, monitors)

    recovered =
      Map.merge(entry, %{
        caller: caller,
        keeper: keeper,
        caller_monitor: caller_monitor,
        keeper_monitor: keeper_monitor,
        child_monitor: child_monitor
      })

    {:ok, recovered, monitors}
  end

  defp recover_orphan_entry(entry, child) do
    lease = Map.fetch!(entry, :lease)
    child_id = Map.fetch!(entry, :child_id)
    request_child_stop(child_id)
    child_monitor = Process.monitor(child)

    recovered =
      Map.merge(entry, %{
        caller_monitor: nil,
        keeper_monitor: nil,
        child_monitor: child_monitor
      })

    {:ok, recovered, %{child_monitor => {lease, :child}}}
  end

  defp recover_caller_monitor(caller, keeper, keeper_monitor, _lease, monitors)
       when caller == keeper,
       do: {keeper_monitor, monitors}

  defp recover_caller_monitor(caller, _keeper, _keeper_monitor, lease, monitors) do
    case Process.alive?(caller) do
      true ->
        monitor = Process.monitor(caller)
        {monitor, Map.put(monitors, monitor, {lease, :caller})}

      false ->
        {nil, monitors}
    end
  end

  defp recover_child_monitor(nil, _lease, monitors), do: {nil, monitors}

  defp recover_child_monitor(child, lease, monitors) do
    monitor = Process.monitor(child)
    {monitor, Map.put(monitors, monitor, {lease, :child})}
  end

  defp new_entry(lease, root_id, parent_id, caller, keeper) do
    keeper_monitor = Process.monitor(keeper)

    {caller_monitor, monitors} =
      case caller == keeper do
        true ->
          {keeper_monitor, %{keeper_monitor => {lease, :keeper}}}

        false ->
          caller_monitor = Process.monitor(caller)

          {caller_monitor,
           %{
             keeper_monitor => {lease, :keeper},
             caller_monitor => {lease, :caller}
           }}
      end

    entry = %{
      lease: lease,
      root_id: root_id,
      parent_id: parent_id,
      caller: caller,
      keeper: keeper,
      caller_monitor: caller_monitor,
      keeper_monitor: keeper_monitor,
      child_id: nil,
      child: nil,
      child_monitor: nil
    }

    {entry, monitors}
  end

  defp validate_reservation(root_id, parent_id, limit, caller, keeper) do
    cond do
      not nonblank?(root_id) -> {:error, {:invalid_root_session_id, root_id}}
      not nonblank?(parent_id) -> {:error, {:invalid_parent_session_id, parent_id}}
      not (is_integer(limit) and limit > 0) -> {:error, {:invalid_subagent_limit, limit}}
      not is_pid(caller) -> {:error, {:invalid_lease_owner, caller}}
      not is_pid(keeper) -> {:error, {:invalid_lease_keeper, keeper}}
      true -> :ok
    end
  end

  defp validate_child(child_id, child) do
    cond do
      not nonblank?(child_id) -> {:error, {:invalid_child_session_id, child_id}}
      not is_pid(child) -> {:error, {:invalid_child_pid, child}}
      true -> :ok
    end
  end

  defp ensure_capacity(state, root_id, limit) do
    case length(:ets.lookup(state.table, root_id)) < limit do
      true -> :ok
      false -> {:error, {:subagent_concurrency_limit, root_id, limit}}
    end
  end

  defp fetch_unattached(state, lease) do
    case Map.fetch(state.leases, lease) do
      {:ok, %{child: nil} = entry} -> {:ok, entry}
      {:ok, _attached} -> {:error, {:lease_already_attached, lease}}
      :error -> {:error, {:unknown_child_lease, lease}}
    end
  end

  defp detach_caller(state, lease, monitor) do
    case Map.fetch(state.leases, lease) do
      {:ok, entry} ->
        detached = %{entry | caller_monitor: nil}
        replace_row(state.table, entry, detached)

        %{
          state
          | leases: Map.put(state.leases, lease, detached),
            monitors: Map.delete(state.monitors, monitor)
        }

      :error ->
        %{state | monitors: Map.delete(state.monitors, monitor)}
    end
  end

  # A dead keeper (watchdog) is the one process that could still stop the
  # child. Best-effort stop in an unlinked process: `Manager.stop/1` is a
  # synchronous supervisor call that must not block this coordinator, and it
  # must still fire while supervisors are unwinding, so no task supervisor.
  # Capacity stays reserved until the child DOWN event; only unattached
  # reservations are dropped immediately.
  defp reap_orphan(state, lease) do
    case Map.fetch(state.leases, lease) do
      {:ok, %{child_id: child_id, child: child} = entry}
      when is_binary(child_id) and is_pid(child) ->
        case Process.alive?(child) do
          true ->
            request_child_stop(child_id)
            clear_keeper_monitor(state, entry, lease)

          false ->
            drop_lease(state, lease)
        end

      {:ok, %{child_id: child_id}} when is_binary(child_id) ->
        request_child_stop(child_id)
        drop_lease(state, lease)

      _no_child ->
        drop_lease(state, lease)
    end
  end

  defp clear_keeper_monitor(state, entry, lease) do
    # Keeper death implies the cleanup owner is gone; only the child monitor
    # should hold capacity until the session exits.
    demonitor(entry.keeper_monitor)
    demonitor(entry.caller_monitor)

    updated = %{entry | keeper_monitor: nil, caller_monitor: nil}
    replace_row(state.table, entry, updated)

    monitors =
      state.monitors
      |> Map.delete(entry.keeper_monitor)
      |> Map.delete(entry.caller_monitor)

    %{
      state
      | leases: Map.put(state.leases, lease, updated),
        monitors: monitors
    }
  end

  # Prefer the shared task supervisor, but this stop must also fire while
  # supervisors are unwinding (see reap_orphan/2): when the supervisor is
  # already gone or refuses children, fall back to an unsupervised process
  # rather than dropping the only remaining stop request for the child.
  defp request_child_stop(child_id) when is_binary(child_id) do
    stop = fn -> Catalyst.Session.Manager.stop(child_id) end

    case Catalyst.Tasks.start_background(stop) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> stop_unsupervised(stop)
    end
  end

  defp stop_unsupervised(stop) do
    _pid = spawn(stop)
    :ok
  end

  defp drop_lease(state, lease) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        state

      {entry, leases} ->
        :ets.delete_object(state.table, row(entry))
        monitor_refs = entry |> monitor_refs() |> Enum.uniq()
        Enum.each(monitor_refs, &demonitor/1)
        monitors = Enum.reduce(monitor_refs, state.monitors, &Map.delete(&2, &1))
        %{state | leases: leases, monitors: monitors}
    end
  end

  defp replace_row(table, old, new) do
    :ets.delete_object(table, row(old))
    :ets.insert(table, row(new))
  end

  defp row(entry), do: {entry.root_id, entry}

  defp monitor_refs(entry) do
    entry
    |> Map.take([:caller_monitor, :keeper_monitor, :child_monitor])
    |> Map.values()
    |> Enum.reject(&is_nil/1)
  end

  defp public_entry(entry) do
    Map.take(entry, [:lease, :root_id, :parent_id, :caller, :keeper, :child_id, :child])
  end

  defp demonitor(nil), do: :ok
  defp demonitor(monitor), do: Process.demonitor(monitor, [:flush])

  # Shared with Catalyst.Tools.SpawnAgent, which validates the same id/cwd
  # inputs before reserving a lease here.
  @doc false
  @spec nonblank?(term()) :: boolean()
  def nonblank?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""
end
