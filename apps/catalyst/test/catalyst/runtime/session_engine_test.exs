defmodule Catalyst.Runtime.SessionEngineTest do
  use ExUnit.Case, async: false

  alias Catalyst.Contracts.SessionEngine.V1
  alias Catalyst.ExtensionAPI
  alias Catalyst.Runtime.{ExtensionPoints, SessionEngine}
  alias Catalyst.Session.{EngineState, EventEnvelope}

  setup do
    owner = "session_engine_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> ExtensionPoints.purge_owner(owner) end)
    {:ok, owner: owner}
  end

  test "the default engine is an ordinary session-bound claim" do
    assert {:ok, resolution} = SessionEngine.resolve(session_id: "session-1")

    assert resolution.claim.owner == :builtin
    assert resolution.claim.implementation == Catalyst.Session.DefaultEngine
    assert resolution.claim.binding == {:pin, :session}

    assert SessionEngine.metadata(resolution) == %{
             service: "agent.session_engine/default",
             contract: %{id: "catalyst.session-engine", version: 1},
             snapshot_id: resolution.snapshot_id,
             owner: :builtin,
             scope: %{},
             binding: {:pin, :session},
             provenance: :builtin,
             implementation: Catalyst.Session.DefaultEngine
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
end
