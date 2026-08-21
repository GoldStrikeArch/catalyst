defmodule Catalyst.Runtime.GenerationStore do
  @moduledoc """
  Atomic, process-free read store for the active managed generation.

  `Catalyst.Runtime.Generations` serializes writes. Readers fetch one immutable
  persistent-term snapshot, so managed extension points, claims, and
  contributions switch together.
  """

  alias Catalyst.Runtime.{Candidate, Claim, Generation, GenerationId}

  @state_key {__MODULE__, :state}
  @state_lock {__MODULE__, :state_lock}

  @type state :: %{
          active: GenerationId.t() | nil,
          previous: GenerationId.t() | nil,
          generations: %{optional(String.t()) => Generation.t()},
          owners: %{optional(String.t()) => [Catalyst.Extension.Manifest.t()]}
        }

  @doc "Return the active generation, if one has been published."
  @spec active() :: Generation.t() | nil
  def active do
    current = state()

    case current.active do
      nil -> nil
      id -> Map.get(current.generations, GenerationId.to_wire(id))
    end
  end

  @doc "Return the active immutable candidate, if present."
  @spec active_candidate() :: Candidate.t() | nil
  def active_candidate do
    case active() do
      %Generation{candidate: candidate} -> candidate
      nil -> nil
    end
  end

  @doc "Return the active generation identity."
  @spec active_id() :: GenerationId.t() | nil
  def active_id, do: state().active

  @doc "Return the source-owner manifest composition of the active generation."
  @spec owners() :: %{optional(String.t()) => [Catalyst.Extension.Manifest.t()]}
  def owners, do: state().owners

  @doc "List retained generation records in newest-first order."
  @spec list() :: [Generation.t()]
  def list do
    state().generations
    |> Map.values()
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @doc false
  @spec publish(Candidate.t(), map()) :: {:ok, Generation.t(), Generation.t() | nil}
  def publish(%Candidate{} = candidate, owners) when is_map(owners) do
    :global.trans(@state_lock, fn ->
      current = state()
      now = DateTime.utc_now()
      previous = active_generation(current)
      generations = retire_active(current.generations, previous, now)
      candidate = ready_candidate(candidate)

      generation = %Generation{
        id: candidate.id,
        parent: candidate.parent,
        candidate: candidate,
        owners: owners,
        status: :active,
        inserted_at: now,
        activated_at: now
      }

      next = %{
        active: candidate.id,
        previous: current.active,
        generations: Map.put(generations, GenerationId.to_wire(candidate.id), generation),
        owners: owners
      }

      :persistent_term.put(@state_key, next)
      {:ok, generation, previous}
    end)
  end

  @doc false
  @spec reject(Candidate.t(), map(), term()) :: :ok
  def reject(%Candidate{} = candidate, owners, reason) when is_map(owners) do
    :global.trans(@state_lock, fn ->
      current = state()
      now = DateTime.utc_now()

      generation = %Generation{
        id: candidate.id,
        parent: candidate.parent,
        candidate: candidate,
        owners: owners,
        status: :rejected,
        inserted_at: now,
        rejected_at: now,
        reason: reason
      }

      next = %{
        current
        | generations:
            Map.put(current.generations, GenerationId.to_wire(candidate.id), generation)
      }

      :persistent_term.put(@state_key, next)
      :ok
    end)
  end

  @doc false
  @spec deactivate(GenerationId.t(), term()) :: :ok
  def deactivate(%GenerationId{} = expected_id, reason) do
    :global.trans(@state_lock, fn ->
      current = state()
      deactivate_expected(current, expected_id, reason)
      :ok
    end)
  end

  @doc false
  @spec clear() :: :ok
  def clear do
    :global.trans(@state_lock, fn ->
      :persistent_term.put(@state_key, initial_state())
      :ok
    end)
  end

  defp state, do: :persistent_term.get(@state_key, initial_state())

  defp initial_state,
    do: %{active: nil, previous: nil, generations: %{}, owners: %{}}

  defp active_generation(%{active: nil}), do: nil

  defp active_generation(%{active: id, generations: generations}),
    do: Map.get(generations, GenerationId.to_wire(id))

  defp retire_active(generations, nil, _now), do: generations

  defp retire_active(generations, generation, now) do
    retired = %{generation | status: :retired, retired_at: now}
    Map.put(generations, GenerationId.to_wire(generation.id), retired)
  end

  defp deactivate_expected(%{active: expected_id} = current, expected_id, reason) do
    generations =
      case active_generation(current) do
        %Generation{} = generation ->
          failed = %{
            generation
            | status: :failed,
              retired_at: DateTime.utc_now(),
              reason: reason
          }

          Map.put(current.generations, GenerationId.to_wire(expected_id), failed)

        nil ->
          current.generations
      end

    :persistent_term.put(@state_key, %{
      current
      | active: nil,
        owners: %{},
        generations: generations
    })
  end

  defp deactivate_expected(_current, _expected_id, _reason), do: :ok

  defp ready_candidate(candidate) do
    generation = GenerationId.to_wire(candidate.id)

    claims =
      Enum.map(candidate.claims, fn %Claim{} = claim ->
        metadata = Map.put(claim.metadata, :runtime_generation, generation)
        %{claim | health: :ready, metadata: metadata}
      end)

    %{candidate | claims: claims}
  end
end
