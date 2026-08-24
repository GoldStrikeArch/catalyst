defmodule Catalyst.HooksTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Catalyst.Hooks
  alias Catalyst.Runtime.Registry

  setup do
    wait_for_runtime_ready!()
    owner = "hooks_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> Hooks.unregister(owner) end)
    {:ok, owner: owner}
  end

  test "filters run by priority and decisions stop at the first result", %{owner: owner} do
    Hooks.register(:test_filter, fn value, _ctx -> {:ok, value <> "b"} end,
      owner: owner,
      priority: 20
    )

    Hooks.register(:test_filter, fn value, _ctx -> {:ok, value <> "a"} end,
      owner: owner,
      priority: 10
    )

    Hooks.register(:test_decision, fn _ctx -> :cont end, owner: owner, priority: 10)
    Hooks.register(:test_decision, fn _ctx -> {:block, "first"} end, owner: owner, priority: 20)
    Hooks.register(:test_decision, fn _ctx -> {:block, "later"} end, owner: owner, priority: 30)

    assert Hooks.run_filter(:test_filter, "", %{}) == "ab"
    assert Hooks.run_decision(:test_decision, %{}) == {:block, "first"}
  end

  test "crashing, throwing, hanging, and malformed synchronous hooks are skipped", %{owner: owner} do
    previous = Application.fetch_env(:catalyst, :hook_handler_timeout)
    Application.put_env(:catalyst, :hook_handler_timeout, 10)
    on_exit(fn -> restore_env(:hook_handler_timeout, previous) end)

    Hooks.register(:test_filter, fn _value, _ctx -> raise "boom" end,
      owner: owner,
      priority: 10
    )

    Hooks.register(:test_filter, fn _value, _ctx -> throw(:nope) end,
      owner: owner,
      priority: 20
    )

    Hooks.register(
      :test_filter,
      fn _value, _ctx ->
        receive do
          :never -> {:ok, "never"}
        end
      end,
      owner: owner,
      priority: 30
    )

    Hooks.register(:test_filter, fn _value, _ctx -> {:ok, :wrong_shape} end,
      owner: owner,
      priority: 40
    )

    Hooks.register(:test_filter, fn value, _ctx -> {:ok, value <> "ok"} end,
      owner: owner,
      priority: 50
    )

    log =
      capture_log(fn ->
        assert Hooks.run_filter(:test_filter, "", %{}, &is_binary/1) == "ok"
      end)

    assert log =~ "raised"
    assert log =~ "timed out"
    assert log =~ "malformed"
  end

  test "turn snapshots remain immutable while live handlers change", %{owner: owner} do
    Hooks.register(:transform_context, fn messages, _ctx -> {:ok, messages ++ [:old]} end,
      owner: owner
    )

    assert {:ok, snapshot} = Hooks.capture_snapshot([:transform_context])
    Hooks.unregister(owner)

    Hooks.register(:transform_context, fn messages, _ctx -> {:ok, messages ++ [:new]} end,
      owner: owner
    )

    assert {:ok, [:old]} = Hooks.transform_context([], %{}, snapshot)
    assert Hooks.run_filter(:transform_context, [], %{}, &is_list/1) == [:new]
  end

  test "before-tool gates fail closed while the runtime is rebuilding", %{owner: owner} do
    key = {Hooks, :runtime_ready}
    previous = :persistent_term.get(key, :missing)
    on_exit(fn -> restore_persistent_term(key, previous) end)

    Hooks.register(:before_tool_call, fn _ctx -> :cont end, owner: owner)
    :ok = Hooks.begin_runtime_rebuild()

    assert Hooks.before_tool_call(%{}) == {:block, :extension_runtime_recovering}
    assert {:error, :extension_runtime_recovering} = Hooks.capture_snapshot()

    Hooks.mark_runtime_ready()
    assert Hooks.before_tool_call(%{}) == :none
  end

  test "event observers receive mailbox-ordered events asynchronously", %{owner: owner} do
    parent = self()

    Hooks.on(
      fn event ->
        send(parent, {:observer_started, event, self()})

        receive do
          {:release, ^event} -> send(parent, {:observer_finished, event})
        end
      end,
      owner: owner
    )

    assert :ok = Hooks.notify(:first, :session)
    assert_receive {:observer_started, :first, observer}
    assert :ok = Hooks.notify(:second, :session)
    refute_receive {:observer_started, :second, _pid}, 0

    send(observer, {:release, :first})
    assert_receive {:observer_finished, :first}
    assert_receive {:observer_started, :second, ^observer}
    send(observer, {:release, :second})
    assert_receive {:observer_finished, :second}
    assert :ok = Hooks.await_observers(:session)
  end

  test "a slow observer does not delay notification or another observer", %{owner: owner} do
    parent = self()
    other = owner <> "_other"
    on_exit(fn -> Hooks.unregister(other) end)

    Hooks.on(
      fn event ->
        send(parent, {:slow_started, self()})

        receive do
          {:release, ^event} -> :ok
        end
      end,
      owner: owner
    )

    Hooks.on(fn event -> send(parent, {:fast_observer, event}) end, owner: other)

    assert :ok = Hooks.notify(:event, :session)
    assert_receive {:slow_started, slow}
    assert_receive {:fast_observer, :event}
    send(slow, {:release, :event})
    assert :ok = Hooks.await_observers(:session)
  end

  test "observer failures are isolated and unregister revokes delivery", %{owner: owner} do
    parent = self()
    other = owner <> "_other"
    on_exit(fn -> Hooks.unregister(other) end)

    Hooks.on(fn _event -> raise "observer boom" end, owner: owner)
    Hooks.on(fn event -> send(parent, {:survivor, event}) end, owner: other)

    log =
      capture_log(fn ->
        assert :ok = Hooks.notify(:first)
        assert :ok = Hooks.await_observers()
      end)

    assert log =~ "observer boom"
    assert_receive {:survivor, :first}

    Hooks.unregister(other)
    assert :ok = Hooks.notify(:second)
    refute_receive {:survivor, :second}
  end

  test "registered handlers use the shared owner purge path", %{owner: owner} do
    Hooks.register(:test_filter, fn value, _ctx -> {:ok, value <> "survived"} end, owner: owner)
    assert Enum.any?(Hooks.handlers(:test_filter), &(&1.owner == owner))
    assert Hooks.run_filter(:test_filter, "", %{}) == "survived"
    assert Enum.any?(Registry.list(:hook), &(&1.owner == owner))

    assert :ok = Hooks.unregister(owner)
    refute Enum.any?(Registry.list(:hook), &(&1.owner == owner))
    assert Hooks.handlers(:test_filter) == []
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:catalyst, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:catalyst, key)

  defp restore_persistent_term(key, :missing), do: :persistent_term.erase(key)
  defp restore_persistent_term(key, value), do: :persistent_term.put(key, value)

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
end
