defmodule Catalyst.Runtime.ArtifactsTest do
  use ExUnit.Case, async: false

  alias Catalyst.Runtime.{ActivationId, ArtifactId, ArtifactSet, Artifacts}

  setup do
    :ok = Artifacts.clear()
    on_exit(fn -> Artifacts.clear() end)
    :ok
  end

  test "pending artifacts are purged when discarded" do
    artifact = compile_artifact(:pending)
    physical = artifact |> ArtifactSet.physical_modules() |> List.first()

    assert :ok = Artifacts.register(artifact)
    assert {:ok, [%{status: :pending, activations: activations}]} = Artifacts.snapshot()
    assert MapSet.size(activations) == 0
    assert :code.is_loaded(physical) != false

    assert :ok = Artifacts.discard([artifact.id])
    assert {:ok, []} = Artifacts.snapshot()
    assert :code.is_loaded(physical) == false
  end

  test "attached artifacts survive discard and purge after activation release" do
    artifact = compile_artifact(:retained)
    activation = ActivationId.new()
    physical = artifact |> ArtifactSet.physical_modules() |> List.first()

    assert :ok = Artifacts.register(artifact)
    assert :ok = Artifacts.attach(activation, [artifact.id])
    assert :ok = Artifacts.discard([artifact.id])

    assert {:ok, [%{status: :retained, activations: activations}]} = Artifacts.snapshot()
    assert MapSet.member?(activations, activation)
    assert :code.is_loaded(physical) != false

    assert :ok = Artifacts.release_activation(activation)
    assert {:ok, []} = Artifacts.snapshot()
    assert :code.is_loaded(physical) == false
  end

  test "releasing an activation does not purge an unrelated pending artifact" do
    retained = compile_artifact(:retained)
    pending = compile_artifact(:pending)
    activation = ActivationId.new()
    pending_module = pending |> ArtifactSet.physical_modules() |> List.first()

    assert :ok = Artifacts.register(retained)
    assert :ok = Artifacts.attach(activation, [retained.id])
    assert :ok = Artifacts.register(pending)

    assert :ok = Artifacts.release_activation(activation)

    assert {:ok, [%{id: pending_id, status: :pending}]} = Artifacts.snapshot()
    assert pending_id == pending.id
    assert :code.is_loaded(pending_module) != false
  end

  test "attach is atomic when any referenced artifact is unknown" do
    artifact = compile_artifact(:known)
    activation = ActivationId.new()

    assert :ok = Artifacts.register(artifact)

    assert {:error, {:unknown_artifact, _wire_id}} =
             Artifacts.attach(activation, [artifact.id, ArtifactId.new()])

    assert {:ok, [%{status: :pending, activations: activations}]} = Artifacts.snapshot()
    assert MapSet.size(activations) == 0
  end

  defp compile_artifact(marker) do
    id = ArtifactId.new()
    logical = Module.concat(__MODULE__, "Logical#{System.unique_integer([:positive])}")

    physical =
      Module.concat([
        Catalyst,
        RuntimeArtifact,
        ArtifactId.module_segment(id),
        "Probe"
      ])

    [{^physical, beam}] =
      Code.compile_string("""
      defmodule #{inspect(physical)} do
        def marker, do: #{inspect(marker)}
      end
      """)

    ArtifactSet.new(id, %{logical => physical}, %{physical => beam})
  end
end
