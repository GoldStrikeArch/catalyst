defmodule Catalyst.Agent.ChildrenTest do
  use ExUnit.Case, async: false

  alias Catalyst.Agent.Children
  alias Catalyst.Agent.Children.TableOwner

  @table :catalyst_agent_children_test

  setup do
    server = start_supervised!({Children, name: nil, table: @table})
    %{server: server}
  end

  test "root-tree reservations enforce the limit atomically and release idempotently", %{
    server: server
  } do
    assert {:ok, lease} = Children.reserve("root", "parent-a", 1, server: server)

    assert {:error, {:subagent_concurrency_limit, "root", 1}} =
             Children.reserve("root", "parent-b", 1, server: server)

    assert [%{lease: ^lease, root_id: "root", parent_id: "parent-a", child: nil}] =
             Children.list("root", server: server)

    assert :ok = Children.release(lease, server: server)
    assert :ok = Children.release(lease, server: server)
    assert Children.count("root", server: server) == 0
  end

  test "a child DOWN releases its attached lease", %{server: server} do
    child =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :stop -> :ok
           end
         end}
      )

    child_ref = Process.monitor(child)

    assert {:ok, lease} = Children.reserve("root", "parent", 2, server: server)
    assert :ok = Children.attach(lease, "parent_schild", child, server: server)

    assert [%{child_id: "parent_schild", child: ^child}] =
             Children.list("root", server: server)

    send(child, :stop)
    assert_receive {:DOWN, ^child_ref, :process, ^child, :normal}
    assert_synchronized_count(server, "root", 0)
  end

  test "the calling tool process owns the lease and its DOWN frees capacity", %{server: server} do
    parent = self()

    caller =
      start_supervised!(
        {Task,
         fn ->
           {:ok, lease} = Children.reserve("tree", "parent", 1, server: server)
           send(parent, {:reserved, self(), lease})

           receive do
             :finish -> :ok
           end
         end}
      )

    caller_ref = Process.monitor(caller)
    assert_receive {:reserved, ^caller, _lease}
    assert Children.count("tree", server: server) == 1

    send(caller, :finish)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert_synchronized_count(server, "tree", 0)
  end

  test "a distinct cleanup keeper retains capacity after the calling task exits", %{
    server: server
  } do
    caller = start_waiting_task(:lease_caller)
    keeper = start_waiting_task(:lease_keeper)

    assert {:ok, _lease} =
             Children.reserve("kept-tree", "parent", 1,
               server: server,
               caller: caller,
               keeper: keeper
             )

    caller_ref = Process.monitor(caller)
    send(caller, :finish)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert_synchronized_count(server, "kept-tree", 1)

    assert {:error, {:subagent_concurrency_limit, "kept-tree", 1}} =
             Children.reserve("kept-tree", "other", 1, server: server)

    keeper_ref = Process.monitor(keeper)
    send(keeper, :finish)
    assert_receive {:DOWN, ^keeper_ref, :process, ^keeper, :normal}
    assert_synchronized_count(server, "kept-tree", 0)
  end

  test "a dead keeper reaps its still-running attached child session", %{server: server} do
    tmp =
      Path.join(System.tmp_dir!(), "catalyst_children_reap_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, %{id: child_id, pid: child}} = Catalyst.Session.Manager.start_session(cwd: tmp)
    on_exit(fn -> Catalyst.Session.Manager.stop(child_id) end)

    keeper = start_waiting_task(:reap_keeper)

    assert {:ok, lease} =
             Children.reserve("reap-tree", "parent", 1, server: server, keeper: keeper)

    assert :ok = Children.attach(lease, child_id, child, server: server)

    child_ref = Process.monitor(child)
    keeper_ref = Process.monitor(keeper)
    Process.exit(keeper, :kill)
    assert_receive {:DOWN, ^keeper_ref, :process, ^keeper, :killed}

    # Nobody else knows about the orphan: the coordinator must stop the session
    # (best-effort) rather than only dropping the lease.
    assert_receive {:DOWN, ^child_ref, :process, ^child, _reason}, 2_000
    assert_synchronized_count(server, "reap-tree", 0)
  end

  test "a dead keeper holds capacity until the attached child exits", %{server: server} do
    # Use a plain process as the "child" so Manager.stop cannot free capacity
    # early; the lease must stay until the child monitor fires.
    child = start_waiting_task(:orphan_capacity_child)
    keeper = start_waiting_task(:orphan_capacity_keeper)

    assert {:ok, lease} =
             Children.reserve("orphan-capacity", "parent", 1,
               server: server,
               keeper: keeper
             )

    assert :ok = Children.attach(lease, "parent_sorphan", child, server: server)

    keeper_ref = Process.monitor(keeper)
    Process.exit(keeper, :kill)
    assert_receive {:DOWN, ^keeper_ref, :process, ^keeper, :killed}
    _ = :sys.get_state(server)

    assert Children.count("orphan-capacity", server: server) == 1

    assert {:error, {:subagent_concurrency_limit, "orphan-capacity", 1}} =
             Children.reserve("orphan-capacity", "other", 1, server: server)

    child_ref = Process.monitor(child)
    send(child, :finish)
    assert_receive {:DOWN, ^child_ref, :process, ^child, :normal}
    assert_synchronized_count(server, "orphan-capacity", 0)
  end

  test "recovery reaps an orphan when the keeper is already dead" do
    table = :catalyst_agent_children_orphan_recovery_test
    owner_name = :catalyst_agent_children_orphan_recovery_table_owner
    server_name = :catalyst_agent_children_orphan_recovery_server

    start_supervised!(
      {TableOwner, table: table, name: owner_name},
      id: {:children_table_owner, table}
    )

    dead_keeper =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    keeper_ref = Process.monitor(dead_keeper)
    send(dead_keeper, :finish)
    assert_receive {:DOWN, ^keeper_ref, :process, ^dead_keeper, :normal}

    child = start_waiting_task(:orphan_recovery_child)
    child_ref = Process.monitor(child)
    lease = make_ref()

    entry = %{
      lease: lease,
      root_id: "orphan-recovery",
      parent_id: "parent",
      caller: self(),
      keeper: dead_keeper,
      caller_monitor: nil,
      keeper_monitor: nil,
      child_id: "parent_sorphan_recovery",
      child: child,
      child_monitor: nil
    }

    true = :ets.insert(table, {"orphan-recovery", entry})

    start_supervised!(
      {Children, table: table, name: server_name},
      id: {:orphan_recovery_children, table}
    )

    _ = :sys.get_state(Process.whereis(server_name))

    assert [%{lease: ^lease, child: ^child}] =
             Children.list("orphan-recovery", server: server_name)

    assert {:error, {:subagent_concurrency_limit, "orphan-recovery", 1}} =
             Children.reserve("orphan-recovery", "other", 1, server: server_name)

    send(child, :finish)
    assert_receive {:DOWN, ^child_ref, :process, ^child, :normal}
    assert_synchronized_count(server_name, "orphan-recovery", 0)
  end

  test "recovery drops a dead-keeper lease that never attached a child" do
    table = :catalyst_agent_children_unattached_recovery_test
    owner_name = :catalyst_agent_children_unattached_recovery_table_owner
    server_name = :catalyst_agent_children_unattached_recovery_server

    start_supervised!(
      {TableOwner, table: table, name: owner_name},
      id: {:children_table_owner, table}
    )

    dead_keeper =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    keeper_ref = Process.monitor(dead_keeper)
    send(dead_keeper, :finish)
    assert_receive {:DOWN, ^keeper_ref, :process, ^dead_keeper, :normal}

    entry = %{
      lease: make_ref(),
      root_id: "unattached-recovery",
      parent_id: "parent",
      caller: self(),
      keeper: dead_keeper,
      caller_monitor: nil,
      keeper_monitor: nil,
      child_id: nil,
      child: nil,
      child_monitor: nil
    }

    true = :ets.insert(table, {"unattached-recovery", entry})

    # A reserved-but-never-attached row must not crash init/1 into a restart
    # loop; there is no child to hold capacity for, so the lease is dropped.
    start_supervised!(
      {Children, table: table, name: server_name},
      id: {:unattached_recovery_children, table}
    )

    _ = :sys.get_state(Process.whereis(server_name))

    assert Children.list("unattached-recovery", server: server_name) == []

    assert {:ok, _lease} =
             Children.reserve("unattached-recovery", "other", 1, server: server_name)
  end

  test "recovery frees a dead-keeper lease whose child pid was never recorded" do
    table = :catalyst_agent_children_idonly_recovery_test
    owner_name = :catalyst_agent_children_idonly_recovery_table_owner
    server_name = :catalyst_agent_children_idonly_recovery_server

    start_supervised!(
      {TableOwner, table: table, name: owner_name},
      id: {:children_table_owner, table}
    )

    dead_keeper = spawn(fn -> :ok end)
    keeper_ref = Process.monitor(dead_keeper)
    # `:noproc` when the spawn already exited before the monitor attached.
    assert_receive {:DOWN, ^keeper_ref, :process, ^dead_keeper, reason}
                   when reason in [:normal, :noproc]

    entry = %{
      lease: make_ref(),
      root_id: "idonly-recovery",
      parent_id: "parent",
      caller: self(),
      keeper: dead_keeper,
      caller_monitor: nil,
      keeper_monitor: nil,
      child_id: "parent_sidonly_ghost",
      child: nil,
      child_monitor: nil
    }

    true = :ets.insert(table, {"idonly-recovery", entry})

    # Mirrors the live reap_orphan/2 policy: no pid to monitor, so the lease
    # is dropped after a best-effort stop request for the recorded child id.
    start_supervised!(
      {Children, table: table, name: server_name},
      id: {:idonly_recovery_children, table}
    )

    _ = :sys.get_state(Process.whereis(server_name))

    assert Children.list("idonly-recovery", server: server_name) == []
    assert {:ok, _lease} = Children.reserve("idonly-recovery", "other", 1, server: server_name)
  end

  test "a coordinator restart rebuilds live leases from the table owner" do
    table = :catalyst_agent_children_recovery_test
    owner_name = :catalyst_agent_children_recovery_table_owner
    server_name = :catalyst_agent_children_recovery_server

    start_supervised!(
      {TableOwner, table: table, name: owner_name},
      id: {:children_table_owner, table}
    )

    old_server =
      start_supervised!(
        {Children, table: table, name: server_name},
        id: {:recovering_children, table}
      )

    child = start_waiting_task(:recovered_child)
    child_ref = Process.monitor(child)

    assert {:ok, lease} = Children.reserve("recovery-root", "parent", 1, server: server_name)
    assert :ok = Children.attach(lease, "parent_srecovered", child, server: server_name)

    server_ref = Process.monitor(old_server)
    Process.exit(old_server, :kill)
    assert_receive {:DOWN, ^server_ref, :process, ^old_server, :killed}

    new_server = wait_for_server(server_name, old_server)
    _ = :sys.get_state(new_server)

    assert [%{lease: ^lease, child: ^child, child_id: "parent_srecovered"}] =
             Children.list("recovery-root", server: server_name)

    assert {:error, {:subagent_concurrency_limit, "recovery-root", 1}} =
             Children.reserve("recovery-root", "other", 1, server: server_name)

    send(child, :finish)
    assert_receive {:DOWN, ^child_ref, :process, ^child, :normal}
    assert_synchronized_count(server_name, "recovery-root", 0)
  end

  test "one root limit spans parents at multiple depths and every cleanup path frees capacity", %{
    server: server
  } do
    root_id = "root-tree"
    parent = self()

    children =
      for label <- [:first, :second, :third] do
        start_waiting_task({:fanout_child, label})
      end

    owners =
      ["root-tree", "root-tree_schild", "root-tree_schild_sgrandchild"]
      |> Enum.zip(children)
      |> Enum.map(fn {parent_id, child} ->
        start_supervised!(
          {Task,
           fn ->
             {:ok, lease} = Children.reserve(root_id, parent_id, 3, server: server)
             :ok = Children.attach(lease, parent_id <> "_sleaf", child, server: server)
             send(parent, {:fanout_attached, self(), lease})

             receive do
               :finish -> :ok
             end
           end},
          id: {:fanout_owner, make_ref()}
        )
      end)

    leases =
      Enum.map(owners, fn owner ->
        assert_receive {:fanout_attached, ^owner, lease}
        lease
      end)

    assert Children.count(root_id, server: server) == 3

    assert {:error, {:subagent_concurrency_limit, ^root_id, 3}} =
             Children.reserve(root_id, "another-depth", 3, server: server)

    [first_child, second_child, third_child] = children
    [first_owner, second_owner, third_owner] = owners
    [_first_lease, _second_lease, third_lease] = leases

    first_child_ref = Process.monitor(first_child)
    send(first_child, :finish)
    assert_receive {:DOWN, ^first_child_ref, :process, ^first_child, :normal}

    # Keeper death holds capacity while its child is still alive; free that
    # slot by stopping the child, not only the owner process.
    second_owner_ref = Process.monitor(second_owner)
    send(second_owner, :finish)
    assert_receive {:DOWN, ^second_owner_ref, :process, ^second_owner, :normal}

    second_child_ref = Process.monitor(second_child)
    send(second_child, :finish)
    assert_receive {:DOWN, ^second_child_ref, :process, ^second_child, :normal}

    assert :ok = Children.release(third_lease, server: server)
    assert_synchronized_count(server, root_id, 0)

    send(first_owner, :finish)
    send(third_owner, :finish)
    send(third_child, :finish)
  end

  test "invalid reservations and attachments return tagged errors", %{server: server} do
    assert {:error, {:invalid_root_session_id, ""}} =
             Children.reserve("", "parent", 1, server: server)

    assert {:error, {:invalid_subagent_limit, 0}} =
             Children.reserve("root", "parent", 0, server: server)

    assert {:error, {:invalid_lease_keeper, :not_a_pid}} =
             Children.reserve("root", "parent", 1,
               server: server,
               keeper: :not_a_pid
             )

    assert {:ok, lease} = Children.reserve("root", "parent", 1, server: server)

    assert {:error, {:invalid_child_session_id, ""}} =
             Children.attach(lease, "", self(), server: server)

    assert {:error, {:unknown_child_lease, _unknown}} =
             Children.attach(make_ref(), "child", self(), server: server)
  end

  defp wait_for_server(name, old_server, attempts \\ 100)

  defp wait_for_server(_name, _old_server, 0), do: flunk("children server did not restart")

  defp wait_for_server(name, old_server, attempts) do
    case Process.whereis(name) do
      server when is_pid(server) and server != old_server ->
        server

      _not_restarted ->
        receive do
        after
          10 -> wait_for_server(name, old_server, attempts - 1)
        end
    end
  end

  defp assert_synchronized_count(server, root_id, expected) do
    _ = :sys.get_state(server)
    assert Children.count(root_id, server: server) == expected
  end

  defp start_waiting_task(id) do
    start_supervised!(
      {Task,
       fn ->
         receive do
           :finish -> :ok
         end
       end},
      id: id
    )
  end
end
