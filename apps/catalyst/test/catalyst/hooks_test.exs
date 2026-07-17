defmodule Catalyst.HooksTest do
  # async: false — Hooks is global, shared, mutable state. Tests use synthetic
  # hook points (:test_*) and a sentinel event ref so they can't perturb (or be
  # perturbed by) the real loop hook points used by other tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Catalyst.Agent.Event
  alias Catalyst.Hooks
  alias Catalyst.Hooks.ObserverDispatcher

  setup do
    owner = "hooks_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> Hooks.unregister(owner) end)
    {:ok, owner: owner}
  end

  test "run_filter folds a value through handlers in priority order", %{owner: owner} do
    Hooks.register(:test_filter, fn v, _ctx -> {:ok, v <> "a"} end, owner: owner, priority: 10)
    Hooks.register(:test_filter, fn v, _ctx -> {:ok, v <> "b"} end, owner: owner, priority: 20)

    assert Hooks.run_filter(:test_filter, "", %{}) == "ab"
  end

  test "run_filter passes the value through when a handler abstains", %{owner: owner} do
    Hooks.register(:test_filter, fn _v, _ctx -> :cont end, owner: owner)
    assert Hooks.run_filter(:test_filter, "x", %{}) == "x"
  end

  test "run_decision returns the first non-abstaining decision", %{owner: owner} do
    Hooks.register(:test_decision, fn _ctx -> :cont end, owner: owner, priority: 10)
    Hooks.register(:test_decision, fn _ctx -> {:block, "no"} end, owner: owner, priority: 20)
    Hooks.register(:test_decision, fn _ctx -> {:block, "later"} end, owner: owner, priority: 30)

    assert Hooks.run_decision(:test_decision, %{}) == {:block, "no"}
  end

  test "run_decision returns :none when all handlers abstain", %{owner: owner} do
    Hooks.register(:test_decision, fn _ctx -> :cont end, owner: owner)
    assert Hooks.run_decision(:test_decision, %{}) == :none
  end

  test "a crashing handler is logged and skipped (filter)", %{owner: owner} do
    Hooks.register(:test_filter, fn _v, _ctx -> raise "boom" end, owner: owner, priority: 10)
    Hooks.register(:test_filter, fn v, _ctx -> {:ok, v <> "ok"} end, owner: owner, priority: 20)

    log =
      capture_log(fn ->
        assert Hooks.run_filter(:test_filter, "", %{}) == "ok"
      end)

    assert log =~ "boom"
  end

  test "a crashing handler is logged and skipped (decision)", %{owner: owner} do
    Hooks.register(:test_decision, fn _ctx -> throw(:nope) end, owner: owner, priority: 10)
    Hooks.register(:test_decision, fn _ctx -> {:block, "real"} end, owner: owner, priority: 20)

    capture_log(fn ->
      assert Hooks.run_decision(:test_decision, %{}) == {:block, "real"}
    end)
  end

  test "a hanging handler is killed at the deadline and skipped", %{owner: owner} do
    # The moduledoc promises a misbehaving hook "can never take down or wedge a
    # run" — a handler that merely blocks must be killed, not waited on forever.
    prev = Application.get_env(:catalyst, :hook_handler_timeout)
    Application.put_env(:catalyst, :hook_handler_timeout, 50)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:catalyst, :hook_handler_timeout)
        ms -> Application.put_env(:catalyst, :hook_handler_timeout, ms)
      end
    end)

    Hooks.register(
      :test_filter,
      fn _v, _ctx ->
        receive do
          :never -> :ok
        end
      end,
      owner: owner,
      priority: 10
    )

    Hooks.register(:test_filter, fn v, _ctx -> {:ok, v <> "ok"} end, owner: owner, priority: 20)

    log =
      capture_log(fn ->
        assert Hooks.run_filter(:test_filter, "", %{}) == "ok"
      end)

    assert log =~ "timed out"
  end

  test "a malformed {:ok, value} is shape-checked, logged, and skipped", %{owner: owner} do
    # The wrapper contracts promise a hook "can never take down a run": a hook
    # returning the wrong shape must not poison the fold (the loop destructures
    # after_tool_call as a 4-tuple and prepare_next_turn as a 2-tuple).
    Hooks.register(:after_tool_call, fn _v, _ctx -> {:ok, :done} end, owner: owner, priority: 10)

    Hooks.register(:after_tool_call, fn {c, d, e, t}, _ctx -> {:ok, {c <> "!", d, e, t}} end,
      owner: owner,
      priority: 20
    )

    log =
      capture_log(fn ->
        assert Hooks.after_tool_call({"out", %{}, false, false}, %{}) ==
                 {"out!", %{}, false, false}
      end)

    assert log =~ "malformed"

    Hooks.register(:prepare_next_turn, fn _v, _ctx -> {:ok, "nope"} end, owner: owner)

    capture_log(fn ->
      assert Hooks.prepare_next_turn(%{messages: []}, %{model: nil}, %{}) ==
               {%{messages: []}, %{model: nil}}
    end)
  end

  test "after_tool_call rejects non-boolean error and terminate fields", %{owner: owner} do
    original = {"out", %{}, false, false}

    Hooks.register(
      :after_tool_call,
      fn _value, _ctx -> {:ok, {"poisoned", %{}, :not_boolean, "also-not-boolean"}} end,
      owner: owner
    )

    log = capture_log(fn -> assert Hooks.after_tool_call(original, %{}) == original end)
    assert log =~ "malformed"
  end

  test "unregister/1 removes only that owner's handlers", %{owner: owner} do
    other = "other_#{System.unique_integer([:positive])}"
    on_exit(fn -> Hooks.unregister(other) end)

    Hooks.register(:test_filter, fn v, _ctx -> {:ok, v <> "mine"} end, owner: owner)
    Hooks.register(:test_filter, fn v, _ctx -> {:ok, v <> "other"} end, owner: other)

    Hooks.unregister(owner)

    # Only the other owner's handler should remain in effect.
    assert Hooks.run_filter(:test_filter, "", %{}) == "other"
  end

  test "notify/1 delivers to observers (filtered by a sentinel ref)", %{owner: owner} do
    ref = make_ref()
    pid = self()
    Hooks.on(fn ev -> send(pid, {:obs, ev}) end, owner: owner)

    assert :ok = Hooks.notify({:sentinel, ref})

    assert_receive {:obs, {:sentinel, ^ref}}
    assert :ok = Hooks.await_observers()
  end

  test "a crashing observer is isolated and later observers still run", %{owner: owner} do
    parent = self()
    session = {:crashing_observer, make_ref()}

    Hooks.on(fn _event -> raise "observer boom" end, owner: owner, priority: 10)

    Hooks.on(fn event -> send(parent, {:observer_after_crash, event}) end,
      owner: owner,
      priority: 20
    )

    log =
      capture_log(fn ->
        assert :ok = Hooks.notify(:event, session)
        assert :ok = Hooks.await_observers(session)
      end)

    assert_receive {:observer_after_crash, :event}
    assert log =~ "observer boom"
    assert Process.alive?(Process.whereis(ObserverDispatcher))
  end

  test "event observers are asynchronous and ordered per session", %{owner: owner} do
    parent = self()
    session = {:ordered, make_ref()}

    Hooks.on(
      fn event ->
        send(parent, {:observer_started, session, event, self()})

        receive do
          {:release, ^event} -> send(parent, {:observer_finished, session, event})
        end
      end,
      owner: owner
    )

    assert :ok = Hooks.notify(:first, session)
    assert_receive {:observer_started, ^session, :first, first_pid}, 1_000

    # The dispatcher owns the observer task directly. There is no intermediate
    # per-event task that then starts another task for the callback.
    dispatcher_state = :sys.get_state(ObserverDispatcher)
    assert get_in(dispatcher_state, [:sessions, session, :active, :handler, :pid]) == first_pid

    # The first observer is still blocked, but notification itself and queueing
    # later events return immediately.
    assert :ok = Hooks.notify(:second, session)
    assert :ok = Hooks.notify(:third, session)
    refute_receive {:observer_started, ^session, :second, _pid}, 0

    send(first_pid, {:release, :first})
    assert_receive {:observer_finished, ^session, :first}, 1_000
    assert_receive {:observer_started, ^session, :second, second_pid}, 1_000

    send(second_pid, {:release, :second})
    assert_receive {:observer_finished, ^session, :second}, 1_000
    assert_receive {:observer_started, ^session, :third, third_pid}, 1_000

    send(third_pid, {:release, :third})
    assert_receive {:observer_finished, ^session, :third}, 1_000
    assert :ok = Hooks.await_observers(session)
  end

  test "a blocked session does not delay observers for another session", %{owner: owner} do
    parent = self()
    blocked = {:blocked, make_ref()}
    independent = {:independent, make_ref()}

    Hooks.on(
      fn event ->
        send(parent, {:parallel_observer, event, self()})

        receive do
          {:release, ^event} -> :ok
        end
      end,
      owner: owner
    )

    assert :ok = Hooks.notify(:blocked_event, blocked)
    assert_receive {:parallel_observer, :blocked_event, blocked_pid}, 1_000

    assert :ok = Hooks.notify(:independent_event, independent)
    assert_receive {:parallel_observer, :independent_event, independent_pid}, 1_000

    send(independent_pid, {:release, :independent_event})
    send(blocked_pid, {:release, :blocked_event})
    assert :ok = Hooks.await_observers(independent)
    assert :ok = Hooks.await_observers(blocked)
  end

  test "observer admission is bounded and drops the newest update explicitly", %{owner: owner} do
    put_app_env(:hook_observer_queue_limit, 2)
    parent = self()
    session = {:overflow, make_ref()}

    Hooks.on(
      fn event ->
        send(parent, {:bounded_observer, event, self()})

        receive do
          {:release, ^event} -> :ok
        end
      end,
      owner: owner
    )

    active = %Event.MessageUpdate{llm_event: :accepted_active}
    queued = %Event.MessageUpdate{llm_event: :accepted_queued}
    dropped = %Event.MessageUpdate{llm_event: :dropped_newest}

    assert :ok = Hooks.notify(active, session)
    assert_receive {:bounded_observer, ^active, active_pid}, 1_000
    assert :ok = Hooks.notify(queued, session)

    log =
      capture_log(fn ->
        assert {:dropped, :queue_full} = Hooks.notify(dropped, session)
      end)

    assert log =~ "observer queue full"

    send(active_pid, {:release, active})
    assert_receive {:bounded_observer, ^queued, queued_pid}, 1_000
    refute_receive {:bounded_observer, ^dropped, _pid}, 0

    send(queued_pid, {:release, queued})
    assert :ok = Hooks.await_observers(session)

    dispatcher_state = :sys.get_state(ObserverDispatcher)
    refute Map.has_key?(dispatcher_state.sessions, session)
  end

  test "a lifecycle event evicts a queued stream update at capacity", %{owner: owner} do
    put_app_env(:hook_observer_queue_limit, 2)
    parent = self()
    session = {:lifecycle, make_ref()}

    Hooks.on(
      fn event ->
        send(parent, {:lifecycle_observer, event, self()})

        receive do
          {:release, ^event} -> :ok
        end
      end,
      owner: owner
    )

    active = %Event.MessageUpdate{llm_event: :active}
    evicted = %Event.MessageUpdate{llm_event: :evicted}
    terminal = %Event.MessageEnd{message: :complete}

    assert :ok = Hooks.notify(active, session)
    assert_receive {:lifecycle_observer, ^active, active_pid}, 1_000
    assert :ok = Hooks.notify(evicted, session)

    log = capture_log(fn -> assert :ok = Hooks.notify(terminal, session) end)
    assert log =~ "preserve a lifecycle event"

    send(active_pid, {:release, active})
    assert_receive {:lifecycle_observer, ^terminal, terminal_pid}, 1_000
    refute_receive {:lifecycle_observer, ^evicted, _pid}, 0

    send(terminal_pid, {:release, terminal})
    assert :ok = Hooks.await_observers(session)
  end

  test "a killed notifier cannot leak admission or lose its queued lifecycle event", %{
    owner: owner
  } do
    put_app_env(:hook_observer_queue_limit, 1)
    parent = self()
    session = {:killed_notifier, make_ref()}

    Hooks.on(
      fn event ->
        send(parent, {:durable_lifecycle, event, self()})

        receive do
          {:release, ^event} -> :ok
        end
      end,
      owner: owner
    )

    first = %Event.MessageEnd{message: :first}
    terminal = %Event.AgentEnd{messages: []}

    assert :ok = Hooks.notify(first, session)
    assert_receive {:durable_lifecycle, ^first, first_pid}, 1_000

    notifier = start_supervised!({Task, fn -> Hooks.notify(terminal, session) end})
    _state = :sys.get_state(ObserverDispatcher)
    notifier_ref = Process.monitor(notifier)
    Process.exit(notifier, :kill)
    assert_receive {:DOWN, ^notifier_ref, :process, ^notifier, :killed}

    send(first_pid, {:release, first})
    assert_receive {:durable_lifecycle, ^terminal, terminal_pid}, 1_000
    send(terminal_pid, {:release, terminal})
    assert :ok = Hooks.await_observers(session)

    dispatcher_state = :sys.get_state(ObserverDispatcher)
    refute Map.has_key?(dispatcher_state.sessions, session)
  end

  test "registered handlers survive a Hooks crash (table owned by TableOwner)", %{owner: owner} do
    Hooks.register(:test_filter, fn v, _ctx -> {:ok, v <> "survived"} end, owner: owner)

    pid = Process.whereis(Hooks)
    assert pid, "expected Catalyst.Hooks to be running under the app supervisor"
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # Wait for the supervisor to restart it.
    new_pid =
      Enum.find_value(1..200, fn _ ->
        case Process.whereis(Hooks) do
          nil -> Process.sleep(10) && nil
          p when p == pid -> Process.sleep(10) && nil
          p -> p
        end
      end)

    assert new_pid, "expected the supervisor to restart Catalyst.Hooks"

    # The table outlived the crash: the handler registered before still fires...
    assert Hooks.run_filter(:test_filter, "", %{}) == "survived"

    # ...and the restarted server keeps registering into the same table, with
    # the seq counter resumed (priority tie-break stays registration-ordered).
    Hooks.register(:test_filter, fn v, _ctx -> {:ok, v <> "+new"} end, owner: owner)
    assert Hooks.run_filter(:test_filter, "", %{}) == "survived+new"
  end

  defp put_app_env(key, value) do
    previous = Application.fetch_env(:catalyst, key)
    Application.put_env(:catalyst, key, value)
    on_exit(fn -> restore_app_env(key, previous) end)
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:catalyst, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:catalyst, key)
end
