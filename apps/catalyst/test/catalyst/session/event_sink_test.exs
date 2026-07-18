defmodule Catalyst.Session.EventSinkTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Catalyst.Agent.Event
  alias Catalyst.Hooks
  alias Catalyst.Hooks.ObserverDispatcher
  alias Catalyst.Session.EventSink

  @session_key "test-session"

  describe "committed/2" do
    test "returns promptly when committed dispatcher admission stalls" do
      Application.put_env(:catalyst, :event_sink_deadline_ms, 50)
      on_exit(fn -> Application.delete_env(:catalyst, :event_sink_deadline_ms) end)

      owner = make_ref()
      :ok = Hooks.on(fn _event -> :ok end, owner: owner)
      on_exit(fn -> Hooks.unregister(owner) end)

      :ok = :sys.suspend(ObserverDispatcher)

      try do
        event = %Event.TurnStart{}

        log =
          capture_log(fn ->
            assert :ok = EventSink.committed(event, @session_key)
          end)

        assert log =~ "EventSink dropped committed event due to dispatcher_unavailable"
        assert log =~ inspect(event)
        assert log =~ inspect(@session_key)
      after
        :ok = :sys.resume(ObserverDispatcher)
      end
    end
  end
end
