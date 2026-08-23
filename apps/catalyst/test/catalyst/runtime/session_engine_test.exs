defmodule Catalyst.Runtime.SessionEngineTest do
  use ExUnit.Case, async: false

  alias Catalyst.Contracts.SessionEngine.V1
  alias Catalyst.ExtensionAPI
  alias Catalyst.Runtime.{ExtensionPoints, SessionEngine}
  alias Catalyst.Session.{Effect, EngineState, EventEnvelope, StateCapsule}

  setup do
    owner = "session_engine_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> ExtensionPoints.purge_owner(owner) end)
    {:ok, owner: owner}
  end

  test "the default engine is an ordinary session-bound claim" do
    assert {:ok, resolution} = SessionEngine.resolve(session_id: "session-1")

    assert resolution.claim.owner == :builtin
    assert resolution.claim.implementation == Catalyst.Session.DefaultEngineV2
    assert resolution.claim.binding == {:pin, :session}

    assert SessionEngine.metadata(resolution) == %{
             service: "agent.session_engine/default",
             contract: %{id: "catalyst.session-engine", version: 2},
             snapshot_id: resolution.snapshot_id,
             owner: :builtin,
             scope: %{},
             binding: {:pin, :session},
             provenance: :builtin,
             implementation: Catalyst.Session.DefaultEngineV2
           }
  end

  test "a claimed engine is pinned and invoked through its handle", %{owner: owner} do
    api = ExtensionAPI.new(owner)

    assert :ok =
             ExtensionAPI.claim(api, SessionEngine.key(), Catalyst.Test.SessionEngineA,
               contract: V1.ref(),
               priority: 900
             )

    assert {:ok, handle} = SessionEngine.resolve_and_pin(session_id: "session-1")

    envelope =
      EventEnvelope.new(%Catalyst.Agent.Event.AgentStart{}, "session-1", "run-1")

    assert %EngineState{error_message: "session-engine-a"} =
             SessionEngine.event(handle, envelope, %EngineState{})

    state = %EngineState{error_message: "preserved"}
    assert {:ok, %{version: 1} = snapshot} = SessionEngine.snapshot(handle, state)
    assert {:ok, ^state} = SessionEngine.restore(handle, snapshot)

    assert :ok = SessionEngine.release(handle)
  end

  test "the V2 engine returns bounded effects and carries private state through handoff" do
    assert {:ok, handle} = SessionEngine.resolve_and_pin(session_id: "session-v2")
    assert {:ok, private_state} = SessionEngine.initialize(handle, %{session_id: "session-v2"})

    message = Catalyst.Message.user("hello")

    assert {:ok, state, ^private_state, [%Effect{kind: :start_run}], :ok} =
             SessionEngine.command(
               handle,
               {:prompt, message, :idle},
               %EngineState{},
               private_state
             )

    assert {:ok, capsule} = SessionEngine.snapshot_binding(handle, state, private_state)
    assert %StateCapsule{state_version: 1, source: Catalyst.Session.DefaultEngineV2} = capsule
    assert :ok = StateCapsule.verify(capsule)

    assert {:ok, ^state, ^private_state} = SessionEngine.restore_binding(handle, capsule)
    assert :ok = SessionEngine.release(handle)
  end

  test "state capsules reject process state and detect tampering" do
    assert {:error, :unsafe_state_capsule} =
             StateCapsule.new(
               Catalyst.Contracts.SessionEngine.V2.ref(),
               1,
               Catalyst.Session.DefaultEngineV2,
               %{owner: self()}
             )

    assert {:ok, capsule} =
             StateCapsule.new(
               Catalyst.Contracts.SessionEngine.V2.ref(),
               1,
               Catalyst.Session.DefaultEngineV2,
               %{messages: ["safe"]}
             )

    assert {:error, :state_capsule_checksum_mismatch} =
             StateCapsule.verify(%{capsule | payload: %{messages: ["changed"]}})
  end
end
