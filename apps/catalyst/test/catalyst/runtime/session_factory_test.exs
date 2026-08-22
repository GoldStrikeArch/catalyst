defmodule Catalyst.Runtime.SessionFactoryTest do
  use ExUnit.Case, async: false

  alias Catalyst.Runtime.SessionFactory
  alias Catalyst.Session.Server

  test "the built-in factory is an ordinary local session-bound claim" do
    assert {:ok, resolution} = SessionFactory.resolve(session_id: "session-1")
    assert resolution.claim.owner == :builtin
    assert resolution.claim.implementation == Catalyst.Session.DefaultSessionFactory
    assert resolution.claim.binding == {:pin, :session}

    assert SessionFactory.metadata(resolution) == %{
             service: "agent.session_factory/default",
             contract: %{id: "catalyst.session-factory", version: 1},
             snapshot_id: resolution.snapshot_id,
             owner: :builtin,
             scope: %{},
             binding: {:pin, :session},
             provenance: :builtin,
             implementation: Catalyst.Session.DefaultSessionFactory
           }

    assert {:ok, handle} = SessionFactory.resolve_and_pin(session_id: "session-1")
    assert {:ok, child_spec} = SessionFactory.child_spec(handle, id: "session-1", cwd: "/tmp")
    assert child_spec.restart == :temporary
    assert {Server, :start_link, [opts]} = child_spec.start
    assert opts[:id] == "session-1"
    assert opts[:session_factory_handle] == handle
    assert :ok = SessionFactory.release(handle)
  end
end
