defmodule Catalyst.Runtime.CandidateStager do
  @moduledoc """
  Side-effect boundary for building and staging one complete candidate.

  The generation coordinator runs this module in supervised task work. It starts
  candidate-owned processes and executes health checks, but never publishes the
  active-generation pointer.
  """

  alias Catalyst.Runtime.{
    Candidate,
    CandidateProcesses,
    ExtensionPoints,
    GenerationId,
    HealthChecks
  }

  alias Catalyst.Runtime.Candidate.Builder

  @doc false
  @spec stage(map(), GenerationId.t() | nil) ::
          {:ok, Candidate.t(), pid(), :staged | :already_staged}
          | {:error, term()}
          | {:error, term(), Candidate.t()}
  def stage(owners, parent) when is_map(owners) do
    manifests = owners |> Map.values() |> List.flatten()

    with {:ok, candidate} <-
           Builder.build(manifests,
             extension_points: ExtensionPoints.base_points(),
             existing_claims: ExtensionPoints.base_claims(),
             existing_contributions: ExtensionPoints.base_contributions(),
             parent: parent
           ) do
      stage_candidate(candidate)
    end
  end

  defp stage_candidate(candidate) do
    case CandidateProcesses.alive?(candidate.id) do
      true ->
        {:ok, candidate, candidate_process(candidate.id), :already_staged}

      false ->
        start_and_check(candidate)
    end
  end

  defp start_and_check(candidate) do
    case CandidateProcesses.start(candidate) do
      {:ok, supervisor} ->
        finish_health_checks(candidate, supervisor)

      {:error, reason} ->
        {:error, reason, candidate}
    end
  end

  defp finish_health_checks(candidate, supervisor) do
    case HealthChecks.run(candidate.health_checks) do
      :ok ->
        {:ok, candidate, supervisor, :staged}

      {:error, reason} ->
        CandidateProcesses.stop(supervisor)
        {:error, reason, candidate}
    end
  end

  defp candidate_process(id) do
    case Registry.lookup(
           Catalyst.Runtime.CandidateProcessRegistry,
           GenerationId.to_wire(id)
         ) do
      [{pid, _value}] -> pid
      [] -> raise "candidate process registry lost a live candidate"
    end
  end
end
