defmodule Catalyst.Runtime.HealthChecks do
  @moduledoc """
  Bounded execution of candidate health-check declarations.

  A check succeeds by returning `:ok` or `{:ok, details}`. Every other return,
  exit, or timeout rejects the candidate with a tagged reason.
  """

  alias Catalyst.Tasks

  @doc "Run all health checks in declaration order, stopping at the first failure."
  @spec run([map()]) :: :ok | {:error, term()}
  def run(checks) when is_list(checks) do
    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case run_check(check) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp run_check(check) do
    task = Tasks.async(fn -> apply(check.module, check.function, check.args) end)

    case Tasks.await(task, check.timeout) do
      {:ok, :ok} -> :ok
      {:ok, {:ok, _details}} -> :ok
      {:ok, {:error, reason}} -> {:error, {:health_check_failed, check.id, reason}}
      {:ok, result} -> {:error, {:invalid_health_check_result, check.id, result}}
      {:exit, reason} -> {:error, {:health_check_exit, check.id, reason}}
      :timeout -> {:error, {:health_check_timeout, check.id, check.timeout}}
    end
  end
end
