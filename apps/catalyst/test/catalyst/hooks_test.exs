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
end
