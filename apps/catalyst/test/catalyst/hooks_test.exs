defmodule Catalyst.HooksTest do
  # async: false — Hooks is global, shared, mutable state. Tests use synthetic
  # hook points (:test_*) and a sentinel event ref so they can't perturb (or be
  # perturbed by) the real loop hook points used by other tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Catalyst.Agent.Event
  alias Catalyst.Hooks
  alias Catalyst.Hooks.ObserverDispatcher
  alias Catalyst.Session.EventSink

  setup do
    wait_for_runtime_ready!()
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

    Hooks.register(
      :after_tool_call,
      fn {_content, details, error?, terminate?}, _ctx ->
        {:ok, {Catalyst.Content.text("out!"), details, error?, terminate?}}
      end,
      owner: owner,
      priority: 20
    )

    log =
      capture_log(fn ->
        assert Hooks.after_tool_call({Catalyst.Content.text("out"), %{}, false, false}, %{}) ==
                 {Catalyst.Content.text("out!"), %{}, false, false}
      end)

    assert log =~ "malformed"

    Hooks.register(:prepare_next_turn, fn _v, _ctx -> {:ok, "nope"} end, owner: owner)

    capture_log(fn ->
      assert Hooks.prepare_next_turn(%{messages: []}, %{model: nil}, %{}) ==
               {%{messages: []}, %{model: nil}}
    end)
  end

  test "after_tool_call rejects non-boolean error and terminate fields", %{owner: owner} do
    original = {Catalyst.Content.text("out"), %{}, false, false}

    Hooks.register(
      :after_tool_call,
      fn _value, _ctx ->
        {:ok, {Catalyst.Content.text("poisoned"), %{}, :not_boolean, "also-not-boolean"}}
      end,
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

  test "async lifecycle admission stays bounded without blocking an OTP producer", %{
    owner: owner
  } do
    put_app_env(:hook_observer_queue_limit, 1)
    parent = self()
    session = {:async_lifecycle, make_ref()}

    Hooks.on(
      fn event ->
        send(parent, {:async_observer, event, self()})

        receive do
          {:release, ^event} -> :ok
        end
      end,
      owner: owner
    )

    first = %Event.MessageEnd{message: :first}
    terminal = %Event.AgentEnd{messages: []}

    assert :ok = Hooks.notify(first, session)
    assert_receive {:async_observer, ^first, first_pid}, 1_000
    assert :ok = Hooks.notify_async(terminal, session)

    # Synchronize with the cast. With the sole bounded slot active and no
    # update available to evict, the synthetic lifecycle event is dropped
    # instead of growing an unbounded waiting queue.
    dispatcher_state = :sys.get_state(ObserverDispatcher)
    dispatcher_session = dispatcher_state.sessions[session]
    assert :queue.is_empty(dispatcher_session.waiting)
    assert dispatcher_session.pending == 1
    assert dispatcher_session.dropped == 1

    send(first_pid, {:release, first})
    assert :ok = Hooks.await_observers(session)
    refute_receive {:async_observer, ^terminal, _terminal_pid}
  end

  test "committed lifecycle admission is acknowledged and remains ordered at capacity", %{
    owner: owner
  } do
    put_app_env(:hook_observer_queue_limit, 1)
    parent = self()
    session = {:committed_lifecycle, make_ref()}

    Hooks.on(
      fn event ->
        send(parent, {:committed_observer, event, self()})

        receive do
          {:release, ^event} -> :ok
        end
      end,
      owner: owner
    )

    first = %Event.MessageEnd{message: :first}
    committed = %Event.ContextCompacted{replacement: [:committed]}

    assert :ok = Hooks.notify(first, session)
    assert_receive {:committed_observer, ^first, first_pid}, 1_000
    assert :ok = EventSink.committed(committed, session)

    dispatcher_state = :sys.get_state(ObserverDispatcher)
    assert :queue.len(dispatcher_state.sessions[session].waiting) == 1

    send(first_pid, {:release, first})
    assert_receive {:committed_observer, ^committed, committed_pid}, 1_000
    send(committed_pid, {:release, committed})
    assert :ok = Hooks.await_observers(session)
  end

  test "committed admission waits through a dispatcher restart", %{owner: owner} do
    parent = self()
    session = {:committed_restart, make_ref()}
    event = %Event.ContextCompacted{replacement: [:restart_safe]}

    Hooks.on(fn observed -> send(parent, {:restart_observer, observed}) end, owner: owner)

    dispatcher = Process.whereis(ObserverDispatcher)
    supervisor = parent_supervisor(dispatcher)
    dispatcher_ref = Process.monitor(dispatcher)
    :sys.suspend(supervisor)

    try do
      Process.exit(dispatcher, :kill)
      assert_receive {:DOWN, ^dispatcher_ref, :process, ^dispatcher, :killed}

      _task =
        start_supervised!(
          {Task,
           fn -> send(parent, {:committed_admission, EventSink.committed(event, session)}) end}
        )

      refute_receive {:committed_admission, _result}, 50
    after
      :sys.resume(supervisor)
    end

    _new_dispatcher = wait_for_restart!(ObserverDispatcher, dispatcher, supervisor)
    assert_receive {:committed_admission, :ok}, 1_000
    assert_receive {:restart_observer, ^event}, 1_000
    assert :ok = Hooks.await_observers(session)
  end

  test "a committed retry keeps its first ready handler snapshot", %{owner: owner} do
    parent = self()
    session = {:committed_snapshot, make_ref()}
    event = %Event.ContextCompacted{replacement: [:stable_handlers]}
    replacement_owner = owner <> "_replacement"
    on_exit(fn -> Hooks.unregister(replacement_owner) end)

    Hooks.on(fn observed -> send(parent, {:original_snapshot, observed}) end, owner: owner)

    dispatcher = Process.whereis(ObserverDispatcher)
    supervisor = parent_supervisor(dispatcher)
    dispatcher_ref = Process.monitor(dispatcher)
    :sys.suspend(dispatcher)

    _task =
      start_supervised!(
        {Task, fn -> send(parent, {:snapshot_admission, EventSink.committed(event, session)}) end}
      )

    wait_for_committed_call!(dispatcher, session, event)
    Hooks.unregister(owner)

    Hooks.on(fn observed -> send(parent, {:replacement_snapshot, observed}) end,
      owner: replacement_owner
    )

    Process.exit(dispatcher, :kill)
    assert_receive {:DOWN, ^dispatcher_ref, :process, ^dispatcher, :killed}

    _new_dispatcher = wait_for_restart!(ObserverDispatcher, dispatcher, supervisor)
    assert_receive {:snapshot_admission, :ok}, 1_000
    assert_receive {:original_snapshot, ^event}, 1_000
    refute_receive {:replacement_snapshot, ^event}, 0
    assert :ok = Hooks.await_observers(session)
  end

  test "only the current ready runtime generation can publish handler snapshots", %{
    owner: owner
  } do
    runtime_key = {Hooks, :runtime_ready}
    previous = :persistent_term.get(runtime_key, :missing)
    on_exit(fn -> restore_persistent_term(runtime_key, previous) end)

    Hooks.on(fn _event -> :ok end, owner: owner)

    stale = Hooks.begin_runtime_generation()
    assert {:error, :registry_unavailable} = Hooks.fetch_ready_handlers(:event)

    Hooks.mark_runtime_ready(stale)
    assert {:ok, [_entry | _rest]} = Hooks.fetch_ready_handlers(:event)

    current = Hooks.begin_runtime_generation()
    Hooks.mark_runtime_ready(stale)
    assert {:error, :registry_unavailable} = Hooks.fetch_ready_handlers(:event)

    Hooks.mark_runtime_ready(current)
    assert {:ok, [_entry | _rest]} = Hooks.fetch_ready_handlers(:event)
  end

  test "registered handlers survive a Hooks crash (table owned by TableOwner)", %{owner: owner} do
    Hooks.register(:test_filter, fn v, _ctx -> {:ok, v <> "survived"} end, owner: owner)
    table_owner = Process.whereis(Catalyst.Hooks.TableOwner)
    assert Enum.any?(Hooks.handlers(:test_filter), &(&1.owner == owner))

    pid = Process.whereis(Hooks)
    assert pid, "expected Catalyst.Hooks to be running under the app supervisor"
    supervisor = parent_supervisor(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    new_pid = wait_for_restart!(Hooks, pid, supervisor)
    assert Process.whereis(Catalyst.Hooks.TableOwner) == table_owner
    _ = :sys.get_state(new_pid)

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

  defp parent_supervisor(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    dictionary |> Keyword.fetch!(:"$ancestors") |> List.first()
  end

  defp wait_for_runtime_ready!(attempts \\ 400)

  defp wait_for_runtime_ready!(0), do: flunk("hook runtime never became ready")

  defp wait_for_runtime_ready!(attempts) do
    case Hooks.runtime_ready?() do
      true ->
        :ok

      false ->
        receive do
        after
          5 -> wait_for_runtime_ready!(attempts - 1)
        end
    end
  end

  defp wait_for_committed_call!(dispatcher, session, event, attempts \\ 200)

  defp wait_for_committed_call!(_dispatcher, _session, _event, 0),
    do: flunk("expected a committed dispatcher call")

  defp wait_for_committed_call!(dispatcher, session, event, attempts) do
    {:messages, messages} = Process.info(dispatcher, :messages)

    queued? =
      Enum.any?(messages, fn
        {:"$gen_call", _from, {:enqueue_committed, ^session, ^event, _entries}} -> true
        _other -> false
      end)

    case queued? do
      true ->
        :ok

      false ->
        receive do
        after
          1 -> wait_for_committed_call!(dispatcher, session, event, attempts - 1)
        end
    end
  end

  defp restore_persistent_term(key, :missing), do: :persistent_term.erase(key)
  defp restore_persistent_term(key, value), do: :persistent_term.put(key, value)

  defp wait_for_restart!(name, old_pid, supervisor, attempts \\ 200)

  defp wait_for_restart!(_name, _old_pid, _supervisor, 0),
    do: flunk("expected the supervisor to restart Catalyst.Hooks")

  defp wait_for_restart!(name, old_pid, supervisor, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _not_restarted ->
        _ = :sys.get_state(supervisor)
        wait_for_restart!(name, old_pid, supervisor, attempts - 1)
    end
  end
end
