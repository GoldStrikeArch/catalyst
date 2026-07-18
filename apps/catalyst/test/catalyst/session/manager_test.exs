defmodule Catalyst.Session.ManagerTest do
  # async: false — exercises the shared session DynamicSupervisor directly.
  use ExUnit.Case, async: false

  alias Catalyst.Session.Manager

  setup do
    tmp = Path.join(System.tmp_dir!(), "catalyst_manager_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "a crashed exclusive session is not restarted and spares sibling sessions", %{tmp: tmp} do
    assert {:ok, %{id: sibling_id, pid: sibling}} = Manager.start_session(cwd: tmp)
    on_exit(fn -> Manager.stop(sibling_id) end)

    unique_id = "manager_test_" <> Catalyst.Ids.hex(16)
    assert {:ok, %{pid: unique}} = Manager.start_unique_session(id: unique_id, cwd: tmp)
    on_exit(fn -> Manager.stop(unique_id) end)

    # A permanent restart would retry `create: :exclusive` against the child's
    # own JSONL, fail every attempt, and exhaust the shared supervisor's
    # intensity — killing the sibling. The crash must stay contained instead.
    ref = Process.monitor(unique)
    Process.exit(unique, :kill)
    assert_receive {:DOWN, ^ref, :process, ^unique, :killed}

    _synced = :sys.get_state(Catalyst.Session.DynamicSupervisor)

    assert Manager.whereis(unique_id) == :error
    assert {:ok, ^sibling} = Manager.whereis(sibling_id)
    assert is_map(:sys.get_state(sibling))
  end
end
