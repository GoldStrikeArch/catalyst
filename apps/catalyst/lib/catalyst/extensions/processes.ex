defmodule Catalyst.Extensions.Processes do
  @moduledoc """
  Supervised home for extension-owned processes.

  An extension that needs a long-lived process (a file watcher, a poller, an
  MCP-style client connection) starts it with `Catalyst.ExtensionAPI.start_child/2`.
  Each owner gets its own `DynamicSupervisor` started on demand under the
  top-level `Catalyst.Extensions.ProcessSupervisor` and registered by owner id —
  so purging/reloading an extension terminates its whole process subtree, even
  children the per-owner supervisor restarted in the meantime.
  """

  @top Catalyst.Extensions.ProcessSupervisor
  @registry Catalyst.Extensions.ProcessRegistry

  alias Catalyst.Tasks

  # Reloading an extension purges its owner supervisor and immediately starts
  # new children (commit_load → stop_owner → setup/1 → start_child), but the
  # Registry removes a dead supervisor's `:via` entry ASYNCHRONOUSLY — so for a
  # brief window lookups return a dead pid and re-registration is refused. The
  # start path rides that window out with a short bounded retry instead of
  # reporting a phantom success with no processes started.
  @stale_retry_ms 5
  @stale_retries 10

  # Graceful-shutdown window for an owner's process tree on purge; past it the
  # tree is killed outright (see stop_sup/1).
  @stop_timeout_ms 5_000

  @doc "Start `child_spec` under `owner`'s supervisor (created on first use)."
  @spec start_child(String.t(), Supervisor.child_spec() | {module(), term()} | module()) ::
          DynamicSupervisor.on_start_child() | {:error, term()}
  def start_child(owner, child_spec) when is_binary(owner) do
    do_start_child(owner, child_spec, @stale_retries)
  end

  defp do_start_child(owner, child_spec, retries) do
    case owner_sup(owner) do
      {:ok, sup} ->
        try do
          DynamicSupervisor.start_child(sup, child_spec)
        catch
          # The sup died between lookup and call (a purge racing this start):
          # back off briefly and start a fresh one.
          :exit, {:noproc, _} when retries > 0 ->
            Process.sleep(@stale_retry_ms)
            do_start_child(owner, child_spec, retries - 1)
        end

      {:error, :stale_registry} when retries > 0 ->
        Process.sleep(@stale_retry_ms)
        do_start_child(owner, child_spec, retries - 1)

      {:error, :stale_registry} ->
        {:error, :stale_registry}

      error ->
        error
    end
  end

  @doc "Terminate `owner`'s supervisor and every process under it (purge path)."
  @spec stop_owner(String.t()) :: :ok
  def stop_owner(owner) do
    case Registry.lookup(@registry, owner) do
      [{pid, _}] -> stop_sup(pid)
      [] -> :ok
    end
  end

  # Bounded teardown. Plain terminate_child waits on the children's shutdown
  # specs — extension-authored, so possibly :infinity or exit-trapping — and the
  # purge path runs inside the Catalyst.Extensions GenServer: an unbounded wait
  # there wedges the whole registry (every register/load/uninstall call times
  # out until app restart). Give graceful shutdown a deadline, then kill.
  #
  # Children are snapshotted from the supervisor's links, not via
  # DynamicSupervisor.which_children/1: an extension start MFA runs inside the
  # owner supervisor, so one that never returns also prevents that GenServer
  # call from returning. Proper supervisor children are linked. The supervisor
  # is also linked to its Registry partition, however, so that infrastructure
  # link must be excluded along with the top-level parent. exit(pid, :kill) is
  # untrappable, unlike the :killed propagated by killing the sup, which a
  # trap_exit child could ignore and survive as an orphan.
  defp stop_sup(pid) do
    kids = linked_children(pid)

    task = Tasks.async(fn -> DynamicSupervisor.terminate_child(@top, pid) end)

    case Tasks.await(task, stop_timeout()) do
      {:ok, _result} ->
        :ok

      _timeout_or_exit ->
        Process.exit(pid, :kill)
        Enum.each(kids, &Process.exit(&1, :kill))
        :ok
    end
  end

  defp linked_children(supervisor) do
    infrastructure = infrastructure_links()

    case Process.info(supervisor, :links) do
      {:links, links} -> Enum.reject(links, &MapSet.member?(infrastructure, &1))
      nil -> []
    end
  end

  # Use link snapshots for Catalyst-owned infrastructure too. Unlike a
  # GenServer/Supervisor call, Process.info/2 cannot queue behind an extension
  # callback. Registry partitions are linked to their Registry supervisor, so
  # this excludes every shared partition without relying on private names or
  # process-dictionary metadata.
  defp infrastructure_links do
    registry = Process.whereis(@registry)

    [Process.whereis(@top), registry | process_links(registry)]
    |> Enum.filter(&is_pid/1)
    |> MapSet.new()
  end

  defp process_links(nil), do: []

  defp process_links(pid) do
    case Process.info(pid, :links) do
      {:links, links} -> links
      nil -> []
    end
  end

  defp stop_timeout,
    do: Application.get_env(:catalyst, :extension_stop_timeout, @stop_timeout_ms)

  @doc "Pids of the processes currently running for `owner`."
  @spec list(String.t()) :: [pid()]
  def list(owner) do
    case Registry.lookup(@registry, owner) do
      [{sup, _}] -> children(sup)
      [] -> []
    end
  end

  # The Registry entry of a just-terminated owner supervisor is removed
  # asynchronously, so the lookup can briefly return a dead pid — a dead
  # supervisor has no children.
  defp children(sup) do
    sup |> DynamicSupervisor.which_children() |> Enum.map(fn {_, pid, _, _} -> pid end)
  catch
    :exit, _ -> []
  end

  defp owner_sup(owner) do
    case live_lookup(owner) do
      {:ok, pid} ->
        {:ok, pid}

      :absent ->
        spec = %{
          id: {:ext_sup, owner},
          start:
            {DynamicSupervisor, :start_link,
             [[name: {:via, Registry, {@registry, owner}}, strategy: :one_for_one]]},
          # A purged (or crash-escalated) owner supervisor stays gone; reloading
          # the extension re-creates it on the next start_child.
          restart: :temporary,
          type: :supervisor
        }

        case DynamicSupervisor.start_child(@top, spec) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            # A LIVE pid means someone else created it concurrently — use it.
            # A DEAD pid means the Registry hasn't finished removing a purged
            # sup's name yet: report stale so do_start_child retries shortly.
            if Process.alive?(pid), do: {:ok, pid}, else: {:error, :stale_registry}

          error ->
            error
        end
    end
  end

  # A lookup that returns a dead pid is the stale-Registry window after a
  # purge — treat it as absent rather than handing callers a corpse.
  defp live_lookup(owner) do
    case Registry.lookup(@registry, owner) do
      [{pid, _}] -> if Process.alive?(pid), do: {:ok, pid}, else: :absent
      [] -> :absent
    end
  end
end
