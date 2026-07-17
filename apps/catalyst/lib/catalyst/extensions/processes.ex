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

  @doc "Start `child_spec` under `owner`'s supervisor (created on first use)."
  def start_child(owner, child_spec) when is_binary(owner) do
    with {:ok, sup} <- owner_sup(owner) do
      DynamicSupervisor.start_child(sup, child_spec)
    end
  end

  @doc "Terminate `owner`'s supervisor and every process under it (purge path)."
  def stop_owner(owner) do
    case Registry.lookup(@registry, owner) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@top, pid)
      [] -> :ok
    end
  end

  @doc "Pids of the processes currently running for `owner`."
  def list(owner) do
    case Registry.lookup(@registry, owner) do
      [{sup, _}] ->
        sup |> DynamicSupervisor.which_children() |> Enum.map(fn {_, pid, _, _} -> pid end)

      [] ->
        []
    end
  end

  defp owner_sup(owner) do
    case Registry.lookup(@registry, owner) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
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
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end
end
