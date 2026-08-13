defmodule Catalyst.WorkflowRunTest do
  use ExUnit.Case, async: false

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Model}
  alias Catalyst.Session.{Manager, Server}
  alias Catalyst.Session.Store.Codec
  alias Catalyst.WorkflowRun
  alias Catalyst.WorkflowRun.{Names, Store}

  @attempt_module Catalyst.Test.WorkflowRunAttempt

  setup do
    Process.register(self(), __MODULE__)
    root = Path.join(Application.fetch_env!(:catalyst, :home), "workflow-run-test")
    previous_root = Application.get_env(:catalyst, :workflow_runs_root)
    Application.put_env(:catalyst, :workflow_runs_root, root)

    on_exit(fn ->
      Application.put_env(:catalyst, :workflow_runs_root, previous_root)
      File.rm_rf(root)
    end)

    :ok
  end

  test "progresses stages and applies the tagged retry policy" do
    id = unique_id()
    :ok = WorkflowRun.subscribe(id)

    assert {:ok, %{id: ^id}} =
             WorkflowRun.start(
               id: id,
               attempt_module: @attempt_module,
               input: %{"request" => "ship"},
               stages: [
                 %{"name" => "plan", "max_attempts" => 2},
                 %{"name" => "build"}
               ]
             )

    assert_receive {:workflow_attempt, first, %{"attempt" => 1, "stage_index" => 0}, _emit}
    send(first, {:progress, %{"message" => "planning"}})

    assert_receive {:workflow_run_event, ^id,
                    %{"type" => "progress", "event" => %{"message" => "planning"}}}

    send(first, {:return, {:retry, %{"kind" => "transient"}}})

    assert_receive {:workflow_attempt, retry, %{"attempt" => 2, "stage_index" => 0}, _emit}
    send(retry, {:return, {:ok, %{"plan" => "ready"}}})

    assert_receive {:workflow_attempt, build, context, _emit}
    assert context["attempt"] == 1
    assert context["stage_index"] == 1
    assert context["results"] == [%{"plan" => "ready"}]
    send(build, {:return, {:ok, %{"artifact" => "done"}}})

    assert_receive {:workflow_run_event, ^id,
                    %{"type" => "completed", "checkpoint" => checkpoint}}

    assert checkpoint["status"] == "completed"
    assert checkpoint["results"] == [%{"plan" => "ready"}, %{"artifact" => "done"}]
    assert {:ok, ^checkpoint} = WorkflowRun.get(id)
    assert Enum.any?(WorkflowRun.list(), &(&1["id"] == id))
  end

  test "retries resume the checkpointed child session" do
    id = unique_id()

    assert {:ok, _run} =
             WorkflowRun.start(
               id: id,
               attempt_module: @attempt_module,
               stages: [%{"name" => "repair", "max_attempts" => 2}]
             )

    assert_receive {:workflow_attempt, first, %{"stage_session_id" => nil}, emit}
    emit.(%{"child_session_id" => "child-session"})
    send(first, {:return, {:retry, %{"child_session_id" => "child-session"}}})

    assert_receive {:workflow_attempt, retry,
                    %{"attempt" => 2, "stage_session_id" => "child-session"}, _emit}

    send(retry, {:return, {:ok, %{"artifact" => "repaired"}}})
  end

  test "a parent exit cancels its durable run and active attempt" do
    id = unique_id()
    :ok = WorkflowRun.subscribe(id)

    owner =
      spawn(fn ->
        {:ok, _run} =
          WorkflowRun.start(
            id: id,
            owner: self(),
            attempt_module: @attempt_module,
            stages: [%{"name" => "wait"}]
          )

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:workflow_attempt, attempt, _context, _emit}
    attempt_ref = Process.monitor(attempt)
    send(owner, :stop)

    assert_receive {:DOWN, ^attempt_ref, :process, ^attempt, :shutdown}

    assert_receive {:workflow_run_event, ^id,
                    %{
                      "type" => "cancelled",
                      "checkpoint" => %{"status" => "cancelled", "reason" => reason}
                    }},
                   2_000

    assert reason =~ "parent exited"
  end

  test "cancellation terminates the temporary attempt and persists terminal state" do
    id = unique_id()

    assert {:ok, _run} =
             WorkflowRun.start(
               id: id,
               attempt_module: @attempt_module,
               stages: [%{"name" => "wait"}]
             )

    assert_receive {:workflow_attempt, attempt, _context, _emit}
    monitor_ref = Process.monitor(attempt)

    assert :ok = WorkflowRun.cancel(id, %{"from" => "test"})
    assert_receive {:DOWN, ^monitor_ref, :process, ^attempt, :shutdown}

    assert {:ok, %{"status" => "cancelled", "reason" => %{"from" => "test"}}} =
             WorkflowRun.get(id)
  end

  test "checkpoint transition failure emits a terminal event instead of hanging" do
    id = unique_id()
    :ok = WorkflowRun.subscribe(id)

    assert {:ok, _run} =
             WorkflowRun.start(
               id: id,
               attempt_module: @attempt_module,
               stages: [%{"name" => "persist"}]
             )

    assert_receive {:workflow_attempt, attempt, _context, _emit}
    root = Application.fetch_env!(:catalyst, :workflow_runs_root)
    File.rm_rf!(root)
    File.write!(root, "not a directory")
    send(attempt, {:return, {:ok, %{"artifact" => "done"}}})

    assert_receive {:workflow_run_event, ^id,
                    %{
                      "type" => "failed",
                      "checkpoint" => %{
                        "status" => "failed",
                        "error" => %{"checkpoint_write_failed" => _reason}
                      }
                    }}
  end

  test "failed initial supervisor start leaves an explicitly resumable checkpoint" do
    id = unique_id()
    supervisor = Catalyst.WorkflowRun.DynamicSupervisor

    assert :ok = Supervisor.terminate_child(Catalyst.Supervisor, supervisor)

    on_exit(fn ->
      case Process.whereis(supervisor) do
        nil -> Supervisor.restart_child(Catalyst.Supervisor, supervisor)
        _pid -> :ok
      end
    end)

    assert {:error, {:workflow_run_supervisor, _reason}} =
             WorkflowRun.start(
               id: id,
               attempt_module: @attempt_module,
               stages: [%{"name" => "wait"}]
             )

    assert {:ok, %{"status" => "interrupted"}} = WorkflowRun.get(id)
    assert {:ok, _pid} = Supervisor.restart_child(Catalyst.Supervisor, supervisor)
  end

  test "explicit resume delivers the final artifact to the parent session" do
    id = unique_id()
    parent_id = "workflow-parent-" <> Catalyst.Ids.hex(6)
    cwd = Path.join(Application.fetch_env!(:catalyst, :home), parent_id)
    model = %Model{id: "faux", api: "faux"}

    assert {:ok, %{pid: parent}} =
             Manager.start_session(
               id: parent_id,
               cwd: cwd,
               model: model,
               provider: Catalyst.LLM.Faux
             )

    on_exit(fn ->
      Manager.stop(parent_id)
      File.rm_rf!(cwd)
    end)

    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(parent_id))
    parent_ref = Process.monitor(parent)
    assert :ok = Manager.stop(parent_id)
    assert_receive {:DOWN, ^parent_ref, :process, ^parent, :shutdown}
    assert :ok = Store.put(interrupted_checkpoint(id, parent_id, cwd, model))
    assert {:ok, _run} = WorkflowRun.resume_to_parent(id, attempt_module: @attempt_module)
    assert_receive {:workflow_attempt, attempt, _context, _emit}
    send(attempt, {:return, {:ok, %{"artifact_id" => "result", "artifact" => "recovered"}}})

    assert_receive {:agent_event, ^parent_id, %Event.MessageEnd{message: assistant}}, 2_000
    assert Content.text_of(assistant.content) == "recovered"
    assert {:ok, resumed_parent} = Manager.whereis(parent_id)
    assert Enum.any?(Server.state(resumed_parent).messages, &(&1 == assistant))
  end

  test "a coordinator crash reloads the checkpoint and explicitly restarts its attempt" do
    id = unique_id()
    :ok = WorkflowRun.subscribe(id)

    assert {:ok, _run} =
             WorkflowRun.start(
               id: id,
               attempt_module: @attempt_module,
               stages: [%{"name" => "recover", "max_attempts" => 3}]
             )

    assert_receive {:workflow_attempt, first_attempt, %{"attempt" => 1}, _emit}
    {:ok, coordinator} = Names.whereis(:coordinator, id)
    coordinator_ref = Process.monitor(coordinator)
    first_ref = Process.monitor(first_attempt)
    Process.exit(coordinator, :kill)

    assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :killed}
    assert_receive {:DOWN, ^first_ref, :process, ^first_attempt, :shutdown}
    assert_receive {:workflow_attempt, recovered, %{"attempt" => 2}, _emit}
    send(recovered, {:return, {:ok, %{"recovered" => true}}})

    assert_eventually_completed(id)
  end

  test "boot discovery marks interrupted runs but never starts them" do
    id = unique_id()

    checkpoint = %{
      "version" => 1,
      "id" => id,
      "status" => "running",
      "stages" => [%{"name" => "resume"}],
      "stage_index" => 0,
      "attempt" => 0,
      "input" => %{},
      "results" => [],
      "last_error" => nil,
      "error" => nil,
      "inserted_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-01T00:00:00Z"
    }

    assert :ok = Store.put(checkpoint)
    assert :ok = Store.interrupt_all()
    assert {:ok, %{"status" => "interrupted"}} = WorkflowRun.get(id)
    assert :error = WorkflowRun.whereis(id)

    assert {:ok, _run} = WorkflowRun.resume(id, attempt_module: @attempt_module)
    assert_receive {:workflow_attempt, resumed, %{"attempt" => 1}, _emit}
    send(resumed, {:return, {:ok, "done"}})
  end

  defp assert_eventually_completed(id) do
    assert_receive {:workflow_run_event, ^id, %{"type" => "completed"}}
    assert {:ok, %{"status" => "completed"}} = WorkflowRun.get(id)
  end

  defp interrupted_checkpoint(id, parent_id, cwd, model) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "version" => 1,
      "id" => id,
      "status" => "interrupted",
      "stages" => [%{"name" => "resume", "max_attempts" => 1}],
      "stage_index" => 0,
      "attempt" => 0,
      "stage_session_id" => nil,
      "input" => %{
        "parent_session_id" => parent_id,
        "cwd" => cwd,
        "model" => Codec.encode_model(model)
      },
      "results" => [],
      "last_error" => nil,
      "error" => nil,
      "inserted_at" => now,
      "updated_at" => now
    }
  end

  defp unique_id, do: "workflow-run-test-" <> Catalyst.Ids.hex(6)
end
