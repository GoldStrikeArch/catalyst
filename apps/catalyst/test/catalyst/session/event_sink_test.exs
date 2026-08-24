defmodule Catalyst.Session.EventSinkTest do
  use ExUnit.Case, async: false

  alias Catalyst.Agent.Event
  alias Catalyst.Hooks
  alias Catalyst.Session.EventSink

  test "committed/2 broadcasts without waiting for observer callbacks" do
    owner = make_ref()
    parent = self()
    on_exit(fn -> Hooks.unregister(owner) end)

    :ok =
      Hooks.on(
        fn event ->
          send(parent, {:observer_started, event, self()})

          receive do
            :release -> :ok
          end
        end,
        owner: owner
      )

    event = %Event.TurnStart{}
    assert :ok = EventSink.committed(event, "test-session")
    assert_receive {:observer_started, ^event, observer}
    send(observer, :release)
    assert :ok = Hooks.await_observers("test-session")
  end
end
