defmodule Catalyst.WorkflowRun.Names do
  @moduledoc false

  @registry Catalyst.WorkflowRun.Registry

  @spec via(atom(), String.t()) :: {:via, Registry, {module(), {atom(), String.t()}}}
  def via(kind, id), do: {:via, Registry, {@registry, {kind, id}}}

  @spec whereis(atom(), String.t()) :: {:ok, pid()} | :error
  def whereis(kind, id) do
    case Registry.lookup(@registry, {kind, id}) do
      [{pid, _value}] -> live_pid(pid)
      [] -> :error
    end
  end

  defp live_pid(pid) do
    case Process.alive?(pid) do
      true -> {:ok, pid}
      false -> :error
    end
  end
end
