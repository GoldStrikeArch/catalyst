defmodule Catalyst.Runtime.GenerationStore do
  @moduledoc """
  Atomic, process-free read store for the active managed generation.

  `Catalyst.Runtime.Generations` serializes writes. Readers fetch one immutable
  persistent-term snapshot, so managed extension points, claims, and
  contributions switch together.
  """

  alias Catalyst.Runtime.{ActivationId, Candidate, Claim, Generation}

  @state_key {__MODULE__, :state}
  @state_lock {__MODULE__, :state_lock}

  @type state :: %{
          active: ActivationId.t() | nil,
          previous: ActivationId.t() | nil,
          generations: %{optional(String.t()) => Generation.t()},
          owners: %{optional(String.t()) => [Catalyst.Extension.Manifest.t()]}
        }

  @doc "Return the active generation, if one has been published."
  @spec active() :: Generation.t() | nil
  def active do
    current = state()

    case current.active do
      nil -> nil
      id -> Map.get(current.generations, ActivationId.to_wire(id))
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
  @spec active_id() :: ActivationId.t() | nil
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

  @doc "Fetch one retained generation by identity."
  @spec fetch(ActivationId.t()) :: {:ok, Generation.t()} | :error
  def fetch(%ActivationId{} = id) do
    Map.fetch(state().generations, ActivationId.to_wire(id))
  end

  @doc false
  @spec publish(Candidate.t(), map()) :: {:ok, Generation.t(), Generation.t() | nil}
  def publish(%Candidate{} = candidate, owners) when is_map(owners) do
    :global.trans(@state_lock, fn ->
      current = state()
      now = DateTime.utc_now()
      previous = active_generation(current)
      generations = begin_retirement(current.generations, previous, now)
      candidate = ready_candidate(candidate)

      generation = %Generation{
        id: candidate.activation_id,
        graph_id: candidate.id,
        parent: candidate.parent,
        candidate: candidate,
        owners: owners,
        status: :active,
        inserted_at: now,
        activated_at: now
      }

      next = %{
        active: candidate.activation_id,
        previous: current.active,
        generations:
          Map.put(generations, ActivationId.to_wire(candidate.activation_id), generation),
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
        id: candidate.activation_id,
        graph_id: candidate.id,
        parent: candidate.parent,
        candidate: candidate,
        owners: owners,
        status: :rejected,
        inserted_at: now,
        rejected_at: now,
        reason: reason
      }

      generations =
        current.generations
        |> put_rejected(generation)
        |> prune_history()

      next = %{current | generations: generations}

      :persistent_term.put(@state_key, next)
      :ok
    end)
  end

  @doc false
  @spec deactivate(ActivationId.t(), term()) :: :ok
  def deactivate(%ActivationId{} = expected_id, reason) do
    :global.trans(@state_lock, fn ->
      current = state()
      deactivate_expected(current, expected_id, reason)
      :ok
    end)
  end

  @doc false
  @spec fail(ActivationId.t(), term()) :: :ok
  def fail(%ActivationId{} = id, reason) do
    :global.trans(@state_lock, fn ->
      current = state()

      case current.active == id do
        true -> deactivate_expected(current, id, reason)
        false -> fail_expected(current, id, reason)
      end

      :ok
    end)
  end

  @doc false
  @spec rollback(ActivationId.t(), ActivationId.t(), term()) ::
          {:ok, Generation.t()} | {:error, term()}
  def rollback(%ActivationId{} = failed_id, %ActivationId{} = parent_id, reason) do
    :global.trans(@state_lock, fn ->
      current = state()

      with true <- current.active == failed_id,
           %Generation{parent: ^parent_id} = failed <- active_generation(current),
           %Generation{status: :retiring} = parent <-
             Map.get(current.generations, ActivationId.to_wire(parent_id)) do
        rollback_to_parent(current, failed, parent, reason)
      else
        false -> {:error, :stale_active_generation}
        nil -> {:error, :parent_generation_not_retained}
        %Generation{} -> {:error, :parent_generation_not_retained}
      end
    end)
  end

  @doc false
  @spec retire(ActivationId.t(), term()) :: :ok
  def retire(%ActivationId{} = id, reason) do
    :global.trans(@state_lock, fn ->
      current = state()
      retire_expected(current, id, reason)
      :ok
    end)
  end

  @doc false
  @spec mark_drain_timeout(ActivationId.t(), DateTime.t()) :: :ok
  def mark_drain_timeout(%ActivationId{} = id, %DateTime{} = timed_out_at) do
    update_generation(id, fn generation ->
      %{generation | drain_timed_out_at: timed_out_at}
    end)
  end

  @doc false
  @spec mark_forced_retirement(ActivationId.t(), DateTime.t()) :: :ok
  def mark_forced_retirement(%ActivationId{} = id, %DateTime{} = forced_at) do
    update_generation(id, fn generation ->
      %{generation | forced_retirement_at: forced_at}
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
    do: Map.get(generations, ActivationId.to_wire(id))

  defp begin_retirement(generations, nil, _now), do: generations

  defp begin_retirement(generations, generation, now) do
    retiring = %{
      generation
      | status: :retiring,
        retiring_at: now,
        drain_deadline: drain_deadline(now)
    }

    Map.put(generations, ActivationId.to_wire(generation.id), retiring)
  end

  defp put_rejected(generations, generation) do
    key = ActivationId.to_wire(generation.id)

    case Map.get(generations, key) do
      %Generation{status: status} when status in [:active, :retiring] -> generations
      _replaceable -> Map.put(generations, key, generation)
    end
  end

  defp deactivate_expected(%{active: expected_id} = current, expected_id, reason) do
    generations =
      case active_generation(current) do
        %Generation{} = generation ->
          failed = %{
            generation
            | status: :failed,
              retiring_at: DateTime.utc_now(),
              drain_deadline: generation.drain_deadline || drain_deadline(DateTime.utc_now()),
              retired_at: nil,
              reason: reason
          }

          Map.put(current.generations, ActivationId.to_wire(expected_id), failed)

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

  defp fail_expected(current, id, reason) do
    key = ActivationId.to_wire(id)

    case Map.get(current.generations, key) do
      %Generation{} = generation ->
        failed = %{
          generation
          | status: :failed,
            retiring_at: generation.retiring_at || DateTime.utc_now(),
            drain_deadline: generation.drain_deadline || drain_deadline(DateTime.utc_now()),
            retired_at: nil,
            reason: reason
        }

        :persistent_term.put(
          @state_key,
          %{current | generations: Map.put(current.generations, key, failed)}
        )

      nil ->
        :ok
    end
  end

  defp rollback_to_parent(current, failed, parent, reason) do
    now = DateTime.utc_now()

    failed = %{
      failed
      | status: :failed,
        retiring_at: now,
        drain_deadline: failed.drain_deadline || drain_deadline(now),
        retired_at: nil,
        reason: reason
    }

    parent = %{
      parent
      | status: :active,
        activated_at: now,
        retiring_at: nil,
        drain_deadline: nil,
        drain_timed_out_at: nil,
        forced_retirement_at: nil,
        retired_at: nil,
        reason: nil
    }

    generations =
      current.generations
      |> Map.put(ActivationId.to_wire(failed.id), failed)
      |> Map.put(ActivationId.to_wire(parent.id), parent)

    :persistent_term.put(@state_key, %{
      current
      | active: parent.id,
        previous: failed.id,
        generations: generations,
        owners: parent.owners
    })

    {:ok, parent}
  end

  defp retire_expected(current, id, reason) do
    key = ActivationId.to_wire(id)

    case Map.get(current.generations, key) do
      %Generation{status: :retiring} = generation ->
        retired = %{
          generation
          | status: :retired,
            retired_at: DateTime.utc_now(),
            reason: reason
        }

        :persistent_term.put(
          @state_key,
          %{
            current
            | generations: current.generations |> Map.put(key, retired) |> prune_history()
          }
        )

      %Generation{status: :failed} = generation ->
        failed = %{
          generation
          | retired_at: DateTime.utc_now(),
            reason: generation.reason || reason
        }

        :persistent_term.put(
          @state_key,
          %{current | generations: current.generations |> Map.put(key, failed) |> prune_history()}
        )

      _not_retiring ->
        :ok
    end
  end

  defp ready_candidate(candidate) do
    generation = ActivationId.to_wire(candidate.activation_id)

    claims =
      Enum.map(candidate.claims, fn %Claim{} = claim ->
        metadata = Map.put(claim.metadata, :runtime_generation, generation)
        %{claim | health: :ready, metadata: metadata}
      end)

    %{candidate | claims: claims}
  end

  defp update_generation(id, update) do
    :global.trans(@state_lock, fn ->
      current = state()
      key = ActivationId.to_wire(id)

      case Map.fetch(current.generations, key) do
        {:ok, generation} ->
          generations = Map.put(current.generations, key, update.(generation))
          :persistent_term.put(@state_key, %{current | generations: generations})

        :error ->
          :ok
      end

      :ok
    end)
  end

  defp drain_deadline(now) do
    case Catalyst.Runtime.RetirementPolicy.current().drain_timeout do
      :infinity -> nil
      timeout -> DateTime.add(now, timeout, :millisecond)
    end
  end

  defp prune_history(generations) do
    limit = Application.get_env(:catalyst, :runtime_generation_history_limit, 100)

    case is_integer(limit) and limit >= 0 do
      true -> prune_terminal_generations(generations, limit)
      false -> generations
    end
  end

  defp prune_terminal_generations(generations, limit) do
    terminal =
      generations
      |> Map.values()
      |> Enum.filter(&terminal?/1)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    terminal
    |> Enum.drop(limit)
    |> Enum.reduce(generations, fn generation, retained ->
      Map.delete(retained, ActivationId.to_wire(generation.id))
    end)
  end

  defp terminal?(%Generation{status: status}) when status in [:retired, :rejected], do: true
  defp terminal?(%Generation{status: :failed, retired_at: %DateTime{}}), do: true
  defp terminal?(%Generation{}), do: false
end
