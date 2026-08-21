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
    Generation,
    GenerationId,
    GenerationStore,
    HealthChecks,
    Leases,
    RunEngine
  }

  alias Catalyst.Runtime.Candidate.Builder

  @doc false
  @spec stage(map(), GenerationId.t() | nil) ::
          {:ok, Candidate.t(), pid(), :staged}
          | {:error, term()}
          | {:error, term(), Candidate.t()}
  def stage(owners, parent) when is_map(owners) do
    manifests = owners |> Map.values() |> List.flatten()

    with {:ok, candidate} <-
           Builder.build(manifests,
             extension_points: ExtensionPoints.base_points(),
             existing_claims: existing_claims(),
             existing_contributions: ExtensionPoints.base_contributions(),
             parent: parent
           ) do
      stage_candidate(candidate)
    end
  end

  defp existing_claims do
    ExtensionPoints.base_claims()
    |> Kernel.++(RunEngine.unmanaged_claims())
    |> Enum.uniq_by(&Catalyst.Runtime.Claim.stable_key/1)
  end

  defp stage_candidate(candidate) do
    with :ok <- ensure_stageable(candidate.id),
         :ok <- stop_existing(candidate.id) do
      start_and_check(candidate)
    else
      {:error, {:generation_instance_retained, _id, _status, _lease_count} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason, candidate}
    end
  end

  defp ensure_stageable(id) do
    case GenerationStore.fetch(id) do
      {:ok, %Generation{} = generation} ->
        lease_count = Leases.count(id)

        case generation.status in [:active, :retiring] or lease_count > 0 do
          true ->
            {:error,
             {:generation_instance_retained, GenerationId.to_wire(id), generation.status,
              lease_count}}

          false ->
            :ok
        end

      :error ->
        :ok
    end
  end

  defp stop_existing(id) do
    case CandidateProcesses.alive?(id) do
      true ->
        CandidateProcesses.stop(id)

      false ->
        :ok
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
        _result = CandidateProcesses.stop(supervisor)
        {:error, reason, candidate}
    end
  end
end
