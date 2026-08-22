defmodule Catalyst.Runtime.Artifacts do
  @moduledoc """
  Owns generation-qualified BEAM artifacts and their activation references.

  Compilation and graph activation are separate transactions. A compiler first
  registers an `ArtifactSet` as pending. Candidate staging atomically attaches
  every referenced artifact to its activation. Rejected candidates discard
  those references; active and retiring generations retain them until the final
  generation lease drains and retirement releases the activation.

  Physical modules are unique to an artifact, so successful garbage collection
  removes them instead of restoring another module version.
  """

  use GenServer

  require Logger

  alias Catalyst.Runtime.{
    ActivationId,
    Artifact,
    ArtifactId,
    ArtifactSet,
    ImplementationRef
  }

  @default_call_timeout 30_000
  @state_key {__MODULE__, :state}

  @type snapshot_result :: {:ok, [Artifact.t()]} | {:error, term()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Register a newly compiled artifact as pending activation."
  @spec register(ArtifactSet.t()) :: :ok | {:error, term()}
  def register(%ArtifactSet{} = set),
    do: GenServer.call(__MODULE__, {:register, set}, call_timeout())

  @doc false
  @spec fetch_set(ArtifactId.t()) :: {:ok, ArtifactSet.t()} | :error
  def fetch_set(%ArtifactId{} = id) do
    GenServer.call(__MODULE__, {:fetch_set, id}, call_timeout())
  catch
    :exit, _reason -> :error
  end

  @doc "Attach all artifact IDs referenced by a staged candidate to its activation."
  @spec attach(ActivationId.t(), [ArtifactId.t()]) :: :ok | {:error, term()}
  def attach(%ActivationId{} = activation, artifact_ids) when is_list(artifact_ids) do
    GenServer.call(__MODULE__, {:attach, activation, artifact_ids}, call_timeout())
  end

  @doc "Release every artifact retained by an activation and purge unreferenced sets."
  @spec release_activation(ActivationId.t()) :: :ok
  def release_activation(%ActivationId{} = activation) do
    GenServer.call(__MODULE__, {:release_activation, activation}, call_timeout())
  catch
    :exit, _reason -> :ok
  end

  @doc "Discard pending, unreferenced artifacts after rejected compilation or staging."
  @spec discard([ArtifactId.t()]) :: :ok
  def discard(artifact_ids) when is_list(artifact_ids) do
    GenServer.call(__MODULE__, {:discard, artifact_ids}, call_timeout())
  catch
    :exit, _reason -> :ok
  end

  @doc "Retry garbage collection for every unreferenced artifact."
  @spec collect() :: :ok
  def collect, do: GenServer.call(__MODULE__, :collect, call_timeout())

  @doc """
  Purge unreferenced artifacts while conservatively retaining attached code.

  Generation recovery releases activation references only after their surviving
  leases drain, so clearing runtime composition cannot delete code under a run.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear, call_timeout())
  catch
    :exit, _reason -> :ok
  end

  @doc "Return artifact lifecycle records without crashing callers during a restart."
  @spec snapshot() :: snapshot_result()
  def snapshot do
    {:ok, GenServer.call(__MODULE__, :snapshot, call_timeout())}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Extract unique artifact identities from implementation references."
  @spec referenced_ids(term()) :: [ArtifactId.t()]
  def referenced_ids(term) do
    term
    |> collect_references(MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort_by(&ArtifactId.to_wire/1)
  end

  @impl true
  def init(:ok) do
    artifacts = persisted_state()
    report_untracked_modules(artifacts)
    {:ok, artifacts}
  end

  @impl true
  def handle_call({:register, %ArtifactSet{} = set}, _from, artifacts) do
    key = ArtifactId.to_wire(set.id)

    case Map.fetch(artifacts, key) do
      :error ->
        artifact = %Artifact{
          id: set.id,
          set: set,
          status: :pending,
          activations: MapSet.new(),
          inserted_at: DateTime.utc_now()
        }

        reply(:ok, Map.put(artifacts, key, artifact))

      {:ok, %Artifact{set: ^set}} ->
        {:reply, :ok, artifacts}

      {:ok, _artifact} ->
        {:reply, {:error, {:artifact_identity_collision, key}}, artifacts}
    end
  end

  def handle_call({:fetch_set, id}, _from, artifacts) do
    result =
      case Map.fetch(artifacts, ArtifactId.to_wire(id)) do
        {:ok, %Artifact{set: set}} -> {:ok, set}
        :error -> :error
      end

    {:reply, result, artifacts}
  end

  def handle_call({:attach, activation, artifact_ids}, _from, artifacts) do
    case fetch_all(artifacts, artifact_ids) do
      {:ok, records} ->
        retained =
          Enum.reduce(records, artifacts, fn artifact, current ->
            next = %{
              artifact
              | status: :retained,
                activations: MapSet.put(artifact.activations, activation),
                reason: nil
            }

            Map.put(current, ArtifactId.to_wire(artifact.id), next)
          end)

        reply(:ok, retained)

      {:error, _reason} = error ->
        {:reply, error, artifacts}
    end
  end

  def handle_call({:release_activation, activation}, _from, artifacts) do
    next =
      Enum.reduce(artifacts, %{}, fn {key, artifact}, current ->
        case MapSet.member?(artifact.activations, activation) do
          true ->
            artifact
            |> Map.update!(:activations, &MapSet.delete(&1, activation))
            |> retain_or_purge(key, current)

          false ->
            Map.put(current, key, artifact)
        end
      end)

    reply(:ok, next)
  end

  def handle_call({:discard, artifact_ids}, _from, artifacts) do
    next =
      artifact_ids
      |> Enum.map(&ArtifactId.to_wire/1)
      |> Enum.uniq()
      |> Enum.reduce(artifacts, &discard_key/2)

    reply(:ok, next)
  end

  def handle_call(:collect, _from, artifacts) do
    next =
      Enum.reduce(artifacts, %{}, fn {key, artifact}, current ->
        case artifact.status do
          :purge_failed -> retain_or_purge(artifact, key, current)
          _pending_or_retained -> Map.put(current, key, artifact)
        end
      end)

    reply(:ok, next)
  end

  def handle_call(:clear, _from, artifacts) do
    next =
      Enum.reduce(artifacts, %{}, fn {key, artifact}, current ->
        case MapSet.size(artifact.activations) do
          0 -> purge_into(artifact, key, current)
          _retained -> Map.put(current, key, artifact)
        end
      end)

    reply(:ok, next)
  end

  def handle_call(:snapshot, _from, artifacts) do
    snapshot =
      artifacts
      |> Map.values()
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    {:reply, snapshot, artifacts}
  end

  defp fetch_all(artifacts, artifact_ids) do
    artifact_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, records} ->
      case Map.fetch(artifacts, ArtifactId.to_wire(id)) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | records]}}
        :error -> {:halt, {:error, {:unknown_artifact, ArtifactId.to_wire(id)}}}
      end
    end)
  end

  defp discard_key(key, artifacts) do
    case Map.get(artifacts, key) do
      %Artifact{activations: activations} = artifact ->
        case MapSet.size(activations) do
          0 -> purge_into(artifact, key, artifacts)
          _retained -> artifacts
        end

      nil ->
        artifacts
    end
  end

  defp retain_or_purge(%Artifact{activations: activations} = artifact, key, artifacts) do
    case MapSet.size(activations) do
      0 -> purge_into(artifact, key, artifacts)
      _retained -> Map.put(artifacts, key, %{artifact | status: :retained})
    end
  end

  defp purge_into(artifact, key, artifacts) do
    case purge_set(artifact.set) do
      :ok ->
        Map.delete(artifacts, key)

      {:error, failures} ->
        Logger.warning("runtime artifact purge left loaded modules",
          artifact: key,
          failures: inspect(failures)
        )

        failed = %{artifact | status: :purge_failed, reason: {:purge_failed, failures}}
        Map.put(artifacts, key, failed)
    end
  end

  defp purge_set(%ArtifactSet{} = set) do
    failures =
      set
      |> ArtifactSet.physical_modules()
      |> Enum.reduce(%{}, fn module, acc ->
        case purge_module(module) do
          :ok -> acc
          {:error, reason} -> Map.put(acc, module, reason)
        end
      end)

    case failures do
      empty when map_size(empty) == 0 -> :ok
      failures -> {:error, failures}
    end
  end

  defp purge_module(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)

    case :code.is_loaded(module) do
      false -> :ok
      loaded -> {:error, {:still_loaded, loaded}}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp report_untracked_modules(artifacts) do
    tracked =
      artifacts
      |> Map.values()
      |> Enum.flat_map(&ArtifactSet.physical_modules(&1.set))
      |> MapSet.new()

    untracked =
      :code.all_loaded()
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&ArtifactSet.physical_module?/1)
      |> Enum.reject(&MapSet.member?(tracked, &1))

    case untracked do
      [] ->
        :ok

      modules ->
        Logger.warning("retaining untracked runtime artifact modules after recovery",
          modules: inspect(modules)
        )
    end
  end

  defp collect_references(%ImplementationRef{artifact: %ArtifactId{} = id}, ids),
    do: MapSet.put(ids, id)

  defp collect_references(%_struct{} = value, ids) do
    value
    |> Map.from_struct()
    |> collect_references(ids)
  end

  defp collect_references(value, ids) when is_map(value) do
    Enum.reduce(value, ids, fn {key, item}, current ->
      current = collect_references(key, current)
      collect_references(item, current)
    end)
  end

  defp collect_references(value, ids) when is_list(value),
    do: Enum.reduce(value, ids, &collect_references/2)

  defp collect_references(value, ids) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> collect_references(ids)
  end

  defp collect_references(_value, ids), do: ids

  defp reply(result, artifacts) do
    :persistent_term.put(@state_key, artifacts)
    {:reply, result, artifacts}
  end

  defp persisted_state do
    case :persistent_term.get(@state_key, %{}) do
      artifacts when is_map(artifacts) -> artifacts
      _invalid -> %{}
    end
  end

  defp call_timeout do
    Application.get_env(:catalyst, :runtime_artifact_call_timeout, @default_call_timeout)
  end
end
