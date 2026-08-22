defmodule Catalyst.Runtime.GenerationsTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [wait_until: 1]

  alias Catalyst.Contracts.RunEngine.V1
  alias Catalyst.Extension.Manifest
  alias Catalyst.Runtime

  alias Catalyst.Runtime.{
    ArtifactId,
    CandidateProcesses,
    ContractRef,
    ExtensionPoints,
    GenerationStore,
    Generations,
    ImplementationRef,
    Leases,
    ServiceKey
  }

  @host_owner "generation_test_host"
  @contract ContractRef.new!("test.generation-engine", 1)

  defmodule Worker do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, %{}}
  end

  defmodule FailingWorker do
    def start_link(_opts), do: {:error, :worker_rejected_start}
  end

  defmodule IgnoredWorker do
    def start_link(_opts), do: :ignore
  end

  defmodule Health do
    def check(:ok), do: :ok
    def check(:error), do: {:error, :unhealthy}

    def check(:block) do
      test = :persistent_term.get({__MODULE__, :test})
      send(test, {:health_check_blocked, self()})

      receive do
        :release -> :ok
      end
    end
  end

  setup do
    :ok = Generations.clear()
    :ok = ExtensionPoints.purge_owner(@host_owner)

    :ok =
      ExtensionPoints.register_host(
        %{
          id: "test.generation_engine",
          contract: @contract,
          service: {"test", "generation_engine"},
          default_binding: {:pin, :run}
        },
        {__MODULE__, :unused_handler},
        @host_owner
      )

    on_exit(fn ->
      :persistent_term.erase({Health, :test})
      Generations.clear()
      ExtensionPoints.purge_owner(@host_owner)
    end)

    :ok
  end

  test "publishes a complete healthy generation and its process subtree" do
    manifest = healthy_manifest("test.generation.one")

    assert {:ok, generation} = Generations.install("source_one", [manifest])
    assert GenerationStore.active_id() == generation.id

    assert Enum.any?(
             ExtensionPoints.list_claims(),
             &(&1.owner == "test.generation.one" and &1.health == :ready)
           )

    assert Enum.any?(
             ExtensionPoints.list_contributions(),
             &(&1.owner == "test.generation.one" and &1.point == "test.generation_widget")
           )

    assert [worker] = CandidateProcesses.list(generation.id)
    assert %{} = :sys.get_state(worker)
  end

  test "reinstalling an unchanged owner keeps the active candidate alive" do
    manifest = healthy_manifest("test.generation.one")

    assert {:ok, generation} = Generations.install("source_one", [manifest])
    assert [worker] = CandidateProcesses.list(generation.id)

    assert {:ok, same_generation} = Generations.install("source_one", [manifest])
    assert same_generation.id == generation.id
    assert CandidateProcesses.list(generation.id) == [worker]
    assert %{} = :sys.get_state(worker)
  end

  test "a leased superseded generation retires only after its final release" do
    first = healthy_manifest("test.generation.leased")

    assert {:ok, first_generation} = Generations.install("leased_source", [first])
    assert {:ok, lease} = Leases.acquire(first_generation.id, self(), :run)

    second = healthy_manifest("test.generation.replacement")
    assert {:ok, second_generation} = Generations.install("leased_source", [second])

    assert first_generation.id != second_generation.id
    assert CandidateProcesses.alive?(first_generation.id)

    assert %{
             status: :retiring,
             lease_count: 1,
             retiring_at: %DateTime{},
             retired_at: nil
           } = Enum.find(Generations.list(), &(&1.id == first_generation.id))

    assert %{status: :active, lease_count: 0} =
             Enum.find(Generations.list(), &(&1.id == second_generation.id))

    assert :ok = Leases.release(lease)

    wait_until(fn ->
      Enum.any?(Generations.list(), fn generation ->
        generation.id == first_generation.id and generation.status == :retired
      end)
    end)

    wait_until(fn -> not CandidateProcesses.alive?(first_generation.id) end)

    assert %{status: :retired, lease_count: 0, reason: :drained} =
             Enum.find(Generations.list(), &(&1.id == first_generation.id))
  end

  test "the same graph can reactivate without replacing a leased retiring activation" do
    first = healthy_manifest("test.generation.retained-instance")
    assert {:ok, first_generation} = Generations.install("retained_source", [first])
    assert {:ok, lease} = Leases.acquire(first_generation.id, self(), :run)

    second = healthy_manifest("test.generation.failed-successor")
    assert {:ok, second_generation} = Generations.install("retained_source", [second])
    assert :ok = CandidateProcesses.stop(second_generation.id)
    wait_until(fn -> GenerationStore.active_id() == nil end)

    assert {:ok, replacement} = Generations.install("retained_source", [first])
    assert replacement.graph_id == first_generation.graph_id
    assert replacement.id != first_generation.id
    assert CandidateProcesses.alive?(first_generation.id)
    assert CandidateProcesses.alive?(replacement.id)
    assert Leases.count(first_generation.id) == 1

    assert %{status: :retiring} =
             Enum.find(Generations.list(), &(&1.id == first_generation.id))

    assert :ok = Leases.release(lease)
    wait_until(fn -> not CandidateProcesses.alive?(first_generation.id) end)
  end

  test "fails closed when the active candidate process subtree exits" do
    manifest = healthy_manifest("test.generation.one")

    assert {:ok, generation} = Generations.install("source_one", [manifest])
    assert {:ok, lease} = Leases.acquire(generation.id, self(), :run)
    assert :ok = CandidateProcesses.stop(generation.id)
    wait_until(fn -> GenerationStore.active_id() == nil end)

    assert GenerationStore.active_id() == nil
    refute Enum.any?(ExtensionPoints.list_claims(), &(&1.owner == manifest.id))
    assert Leases.count(generation.id) == 1

    failed = Enum.find(Generations.list(), &(&1.id == generation.id))
    assert failed.status == :failed
    assert failed.retired_at == nil
    assert {:candidate_process_exit, _reason} = failed.reason
    assert GenerationStore.owners() == %{}

    assert :ok = Leases.release(lease)

    wait_until(fn ->
      Enum.find(Generations.list(), &(&1.id == generation.id)).retired_at != nil
    end)
  end

  test "a failed health check leaves the prior generation active" do
    assert {:ok, active} =
             Generations.install("source_one", [healthy_manifest("test.generation.one")])

    rejected =
      manifest("test.generation.rejected",
        health_checks: [
          %{id: "unhealthy", module: Health, function: :check, args: [:error], timeout: 100}
        ]
      )

    assert {:error, {:health_check_failed, "unhealthy", :unhealthy}} =
             Generations.install("source_two", [rejected])

    assert GenerationStore.active_id() == active.id
    refute Enum.any?(ExtensionPoints.list_claims(), &(&1.owner == "test.generation.rejected"))

    rejected_generation = Enum.find(Generations.list(), &(&1.status == :rejected))
    assert rejected_generation.reason == {:health_check_failed, "unhealthy", :unhealthy}
    assert CandidateProcesses.list(rejected_generation.id) == []
  end

  test "artifact attachment failure is retained as a rejected generation" do
    artifact_id = ArtifactId.new()

    manifest =
      manifest("test.generation.unknown-artifact",
        services: [
          %{
            key: ServiceKey.new!("test", "generation_engine"),
            contract: @contract,
            implementation:
              ImplementationRef.local(__MODULE__.Engine, __MODULE__.Engine, artifact_id)
          }
        ]
      )

    assert {:error, {:unknown_artifact, artifact_wire}} =
             Generations.install("unknown_artifact_source", [manifest])

    rejected =
      Enum.find(Generations.list(), fn generation ->
        generation.status == :rejected and
          Map.has_key?(generation.owners, "unknown_artifact_source")
      end)

    assert rejected.reason == {:unknown_artifact, artifact_wire}
  end

  test "a timed-out health check leaves the prior generation active" do
    assert {:ok, active} =
             Generations.install("source_one", [healthy_manifest("test.generation.one")])

    timed_out =
      manifest("test.generation.timeout",
        health_checks: [
          %{id: "timeout", module: Health, function: :check, args: [:block], timeout: 20}
        ]
      )

    :persistent_term.put({Health, :test}, self())

    assert {:error, {:health_check_timeout, "timeout", 20}} =
             Generations.install("source_two", [timed_out])

    assert GenerationStore.active_id() == active.id
    assert_receive {:health_check_blocked, _health_check}, 1_000
  end

  test "a failed process start leaves the prior generation active" do
    assert {:ok, active} =
             Generations.install("source_one", [healthy_manifest("test.generation.one")])

    rejected =
      manifest("test.generation.bad-process",
        processes: [
          %{
            id: "bad-worker",
            child_spec: %{
              id: FailingWorker,
              start: {FailingWorker, :start_link, [[]]}
            }
          }
        ]
      )

    assert {:error, {:candidate_process_start_failed, "bad-worker", :worker_rejected_start}} =
             Generations.install("source_two", [rejected])

    assert GenerationStore.active_id() == active.id
    refute Enum.any?(ExtensionPoints.list_claims(), &(&1.owner == "test.generation.bad-process"))
  end

  test "an ignored process start rejects and cleans up the candidate" do
    ignored =
      manifest("test.generation.ignored-process",
        processes: [
          %{
            id: "ignored-worker",
            child_spec: %{
              id: IgnoredWorker,
              start: {IgnoredWorker, :start_link, [[]]}
            }
          }
        ]
      )

    assert {:error, {:candidate_process_ignored, "ignored-worker"}} =
             Generations.install("ignored_source", [ignored])

    rejected = Enum.find(Generations.list(), &(&1.status == :rejected))
    assert CandidateProcesses.list(rejected.id) == []

    assert {:error, {:candidate_process_ignored, "ignored-worker"}} =
             Generations.install("ignored_source", [ignored])

    assert CandidateProcesses.list(rejected.id) == []
  end

  test "concurrent activation attempts are rejected while staging is in progress" do
    :persistent_term.put({Health, :test}, self())

    blocking =
      manifest("test.generation.blocking",
        health_checks: [
          %{id: "blocking", module: Health, function: :check, args: [:block], timeout: 5_000}
        ]
      )

    task = Task.async(fn -> Generations.install("blocking_source", [blocking]) end)

    assert_receive {:health_check_blocked, health_check}, 1_000

    assert {:error, :generation_activation_in_progress} =
             Generations.install("other_source", [
               healthy_manifest("test.generation.concurrent")
             ])

    send(health_check, :release)
    assert {:ok, _generation} = Task.await(task, 5_000)
  end

  test "clear cancels staging and prevents stale publication" do
    :persistent_term.put({Health, :test}, self())

    blocking =
      manifest("test.generation.clear",
        health_checks: [
          %{id: "blocking", module: Health, function: :check, args: [:block], timeout: 5_000}
        ]
      )

    task = Task.async(fn -> Generations.install("blocking_source", [blocking]) end)
    assert_receive {:health_check_blocked, _health_check}, 1_000

    assert :ok = Generations.clear()
    assert {:error, :generation_activation_cancelled} = Task.await(task, 5_000)
    assert GenerationStore.active_id() == nil
    assert GenerationStore.owners() == %{}

    wait_until(fn ->
      DynamicSupervisor.which_children(Catalyst.Runtime.CandidateProcessSupervisor) == []
    end)
  end

  test "clear retains leases while stopping active and retiring process subtrees" do
    first = healthy_manifest("test.generation.clear-leased")
    assert {:ok, first_generation} = Generations.install("clear_source", [first])
    assert {:ok, lease} = Leases.acquire(first_generation.id, self(), :run)

    second = healthy_manifest("test.generation.clear-active")
    assert {:ok, second_generation} = Generations.install("clear_source", [second])

    assert CandidateProcesses.alive?(first_generation.id)
    assert CandidateProcesses.alive?(second_generation.id)
    assert Leases.count(first_generation.id) == 1

    assert :ok = Generations.clear()
    assert GenerationStore.active_id() == nil
    assert GenerationStore.owners() == %{}
    assert Leases.count(first_generation.id) == 1

    wait_until(fn ->
      not CandidateProcesses.alive?(first_generation.id) and
        not CandidateProcesses.alive?(second_generation.id)
    end)

    assert :ok = Leases.release(lease)
    assert Leases.list() == []
  end

  test "removing an owner atomically exposes the remaining composition" do
    first = healthy_manifest("test.generation.one")
    second = manifest("test.generation.two", contributions: [widget("two")])

    assert {:ok, _generation} = Generations.install("source_one", [first])
    assert {:ok, _generation} = Generations.install("source_two", [second])
    assert Enum.any?(ExtensionPoints.list_contributions(), &(&1.owner == second.id))

    assert :ok = Generations.remove_owner("source_two")
    refute Enum.any?(ExtensionPoints.list_contributions(), &(&1.owner == second.id))
    assert Enum.any?(ExtensionPoints.list_claims(), &(&1.owner == first.id))
  end

  test "the active managed run-engine claim is used for new resolutions" do
    run_engine =
      manifest("test.generation.run-engine",
        services: [
          %{
            key: ServiceKey.new!("agent", "run_engine"),
            contract: V1.ref(),
            implementation: __MODULE__.Engine,
            priority: 900
          }
        ]
      )

    assert {:ok, generation} = Generations.install("run_engine_source", [run_engine])
    assert {:ok, resolved} = Runtime.resolve_run_engine([], %{})
    assert resolved.selection.module == __MODULE__.Engine
    assert resolved.resolution.claim.owner == run_engine.id

    assert resolved.selection.source ==
             {:generation, Catalyst.Runtime.ActivationId.to_wire(generation.id), run_engine.id}

    assert {:ok, pinned} = Catalyst.Runtime.RunEngine.pin(resolved)
    assert pinned.handle.generation == generation.id
    assert pinned.handle.lease.binding == :run
    assert Generations.active().lease_count == 1

    assert :ok = Catalyst.Runtime.RunEngine.release(pinned)
    assert Generations.active().lease_count == 0
  end

  test "an unmanaged run engine pins without calling the generation coordinator" do
    assert {:ok, resolved} = Runtime.resolve_run_engine([], %{})
    assert Map.get(resolved.resolution.claim.metadata, :runtime_generation) == nil
    :ok = :sys.suspend(Generations)

    try do
      assert {:ok, pinned} = Catalyst.Runtime.RunEngine.pin(resolved)
      assert pinned.handle.lease == nil
      assert pinned.handle.generation == nil
    after
      :ok = :sys.resume(Generations)
    end
  end

  test "pinning a resolution after its generation is replaced fails as stale" do
    first =
      manifest("test.generation.stale-run-engine",
        services: [
          %{
            key: ServiceKey.new!("agent", "run_engine"),
            contract: V1.ref(),
            implementation: __MODULE__.FirstEngine,
            priority: 900
          }
        ]
      )

    assert {:ok, _generation} = Generations.install("stale_run_engine_source", [first])
    assert {:ok, resolved} = Runtime.resolve_run_engine([], %{})

    second =
      manifest("test.generation.current-run-engine",
        services: [
          %{
            key: ServiceKey.new!("agent", "run_engine"),
            contract: V1.ref(),
            implementation: __MODULE__.SecondEngine,
            priority: 900
          }
        ]
      )

    assert {:ok, current} = Generations.install("stale_run_engine_source", [second])

    assert {:error, {:stale_runtime_generation, requested, active}} =
             Catalyst.Runtime.RunEngine.pin(resolved)

    assert requested != active
    assert active == Catalyst.Runtime.ActivationId.to_wire(current.id)
    assert Leases.list() == []
  end

  test "rejects a managed run-engine claim tied with an imperative workflow" do
    owner = "generation_imperative_workflow"

    on_exit(fn -> Catalyst.Workflow.Registry.unregister_owner(owner) end)

    assert :ok =
             Catalyst.Workflow.Registry.register_workflow(
               :default,
               Catalyst.Agent.Loop,
               owner: owner
             )

    run_engine =
      manifest("test.generation.run-engine-tie",
        services: [
          %{
            key: ServiceKey.new!("agent", "run_engine"),
            contract: V1.ref(),
            implementation: __MODULE__.Engine,
            priority: 800
          }
        ]
      )

    assert {:error, {:existing_claim_conflicts, [_identity]}} =
             Generations.install("run_engine_tie_source", [run_engine])
  end

  test "managed claims retain primary and fallback priorities for one owner" do
    manifest =
      manifest("test.generation.priority-chain",
        services: [
          %{
            key: ServiceKey.new!("test", "generation_engine"),
            contract: @contract,
            implementation: __MODULE__.PrimaryEngine
          },
          %{
            key: ServiceKey.new!("test", "generation_engine"),
            contract: @contract,
            implementation: __MODULE__.FallbackEngine,
            priority: 800
          }
        ]
      )

    assert {:ok, _generation} = Generations.install("priority_source", [manifest])

    priorities =
      ExtensionPoints.list_claims()
      |> Enum.filter(&(&1.owner == manifest.id))
      |> Enum.map(& &1.priority)

    assert priorities == [800, 900]
  end

  def unused_handler(_api, _entry, _opts), do: :ok

  defp healthy_manifest(id) do
    manifest(id,
      services: [
        %{
          key: ServiceKey.new!("test", "generation_engine"),
          contract: @contract,
          implementation: __MODULE__.Engine
        }
      ],
      extension_points: [
        %{id: "test.generation_widget", cardinality: :many}
      ],
      contributions: [widget("primary")],
      processes: [%{id: "worker", child_spec: {Worker, []}}],
      health_checks: [
        %{id: "healthy", module: Health, function: :check, args: [:ok], timeout: 100}
      ]
    )
  end

  defp widget(id) do
    %{point: "test.generation_widget", id: id, value: %{label: id}}
  end

  defp manifest(id, declarations) do
    declarations
    |> Map.new()
    |> Map.merge(%{id: id, version: "1.0.0"})
    |> Manifest.new!()
  end
end
