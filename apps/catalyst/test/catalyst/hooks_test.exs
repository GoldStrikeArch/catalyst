defmodule Catalyst.HooksTest do
  # async: false — Hooks is global, shared, mutable state. Tests use synthetic
  # hook points (:test_*) and a sentinel event ref so they can't perturb (or be
  # perturbed by) the real loop hook points used by other tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Catalyst.Hooks

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

    Hooks.register(:test_filter, fn _v, _ctx -> Process.sleep(:infinity) end,
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

    Hooks.notify({:sentinel, ref})

    assert_receive {:obs, {:sentinel, ^ref}}
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
end
