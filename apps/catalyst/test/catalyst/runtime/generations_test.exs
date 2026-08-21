defmodule Catalyst.Runtime.GenerationsTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [wait_until: 1]

  alias Catalyst.Contracts.RunEngine.V1
  alias Catalyst.Extension.Manifest
  alias Catalyst.Runtime

  alias Catalyst.Runtime.{
    CandidateProcesses,
    ContractRef,
    ExtensionPoints,
    GenerationStore,
    Generations,
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

  test "fails closed when the active candidate process subtree exits" do
    manifest = healthy_manifest("test.generation.one")

    assert {:ok, generation} = Generations.install("source_one", [manifest])
    assert :ok = CandidateProcesses.stop(generation.id)
    wait_until(fn -> GenerationStore.active_id() == nil end)

    assert GenerationStore.active_id() == nil
    refute Enum.any?(ExtensionPoints.list_claims(), &(&1.owner == manifest.id))

    failed = Enum.find(Generations.list(), &(&1.id == generation.id))
    assert failed.status == :failed
    assert {:candidate_process_exit, _reason} = failed.reason
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
             {:generation, Catalyst.Runtime.GenerationId.to_wire(generation.id), run_engine.id}
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
