defmodule Catalyst.TasksTest do
  use ExUnit.Case, async: false

  alias Catalyst.Tasks

  test "await returns successful values and task exits as tagged results" do
    assert {:ok, :done} = Tasks.async(fn -> :done end) |> Tasks.await(1_000)
    assert {:exit, :boom} = Tasks.async(fn -> exit(:boom) end) |> Tasks.await(1_000)
  end

  test "await kills work that exceeds its deadline" do
    task =
      Tasks.async(fn ->
        receive do
          :never -> :ok
        end
      end)

    ref = Process.monitor(task.pid)

    assert :timeout = Tasks.await(task, 10)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}
  end

  test "start_background starts fire-and-forget work" do
    parent = self()

    assert {:ok, _pid} = Tasks.start_background(fn -> send(parent, :background_done) end)
    assert_receive :background_done
  end

  test "a crashing fallback task does not exit its caller" do
    probe_supervisor = start_supervised!({Task.Supervisor, []})
    shared_supervisor = Process.whereis(Catalyst.TaskSupervisor)
    true = Process.unregister(Catalyst.TaskSupervisor)

    try do
      parent = self()

      {:ok, probe} =
        Task.Supervisor.start_child(probe_supervisor, fn ->
          send(parent, {:probe_ready, self()})

          receive do
            :run ->
              result = Tasks.async(fn -> exit(:fallback_boom) end) |> Tasks.await(1_000)
              send(parent, {:fallback_result, self(), result})
          end
        end)

      assert_receive {:probe_ready, ^probe}
      ref = Process.monitor(probe)
      send(probe, :run)

      assert_receive {:fallback_result, ^probe, {:exit, :fallback_boom}}
      assert_receive {:DOWN, ^ref, :process, ^probe, :normal}
    after
      case Process.whereis(Catalyst.TaskSupervisor) do
        nil -> Process.register(shared_supervisor, Catalyst.TaskSupervisor)
        _pid -> :ok
      end
    end
  end

  test "an awaitable task is killed when its caller dies" do
    parent = self()

    caller =
      start_supervised!(
        {Task,
         fn ->
           task =
             Tasks.async(fn ->
               send(parent, {:owned_worker, self()})

               receive do
                 :never -> :ok
               end
             end)

           _result = Tasks.await(task, :infinity)
         end}
      )

    assert_receive {:owned_worker, worker}
    worker_ref = Process.monitor(worker)
    caller_ref = Process.monitor(caller)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
  end
end
