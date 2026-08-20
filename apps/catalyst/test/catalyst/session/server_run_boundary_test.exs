defmodule Catalyst.Session.ServerRunBoundaryTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_runtime_policy: 2, runtime_policy: 1]

  alias Catalyst.Agent.Event
  alias Catalyst.{Hooks, Message, Model}
  alias Catalyst.Prompt.Registry, as: PromptRegistry
  alias Catalyst.Session.{Manager, Server}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "catalyst_run_boundary_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    previous_policy = runtime_policy(PromptRegistry)
    :ok = PromptRegistry.unregister_policy()

    :ok =
      PromptRegistry.register_policy(Catalyst.Test.RunBoundaryPrompt,
        owner: :run_boundary_test
      )

    on_exit(fn ->
      :ok = PromptRegistry.unregister_policy()
      restore_runtime_policy(PromptRegistry, previous_policy)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "a worker prompt error uses the normalized failure path without crashing the server", %{
    tmp: tmp
  } do
    {id, pid} =
      start_session(tmp,
        prompt_mode: {:error, :prompt_blocked},
        workflow_mode: :success
      )

    subscribe(id)

    assert :ok = Server.prompt(pid, "hello")
    assert_receive {:run_boundary_prompt_resolved, "model-a", policy_worker}
    refute policy_worker == pid
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000

    # Server.state/1 is a call: answering it already proves the server
    # survived the worker error (no Process.alive? needed).
    snapshot = Server.state(pid)
    refute snapshot.running
    assert snapshot.run_metadata == nil

    assert [%Message.User{}, %Message.Assistant{stop_reason: :error} = error] = snapshot.messages
    assert error.error_message =~ "{:prompt_resolution, :prompt_blocked}"
  end

  test "a workflow {:error, reason} is not treated as an ordinary successful task result", %{
    tmp: tmp
  } do
    {id, pid} = start_session(tmp, workflow_mode: {:error, :workflow_rejected})
    subscribe(id)

    assert :ok = Server.prompt(pid, "hello")
    {worker, monitor} = await_held_worker({:error, :workflow_rejected})

    active = Server.state(pid)
    assert active.running
    assert active.run_metadata.context.model_id == "model-a"

    send(worker, :run_boundary_release)
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    _ = :sys.get_state(pid)

    snapshot = Server.state(pid)
    refute snapshot.running
    assert snapshot.run_metadata == nil
    assert [%Message.Assistant{stop_reason: :error} = error] = snapshot.messages
    assert error.error_message =~ ":workflow_rejected"
  end

  test "a workflow exit normal without a result uses the normalized failure path", %{tmp: tmp} do
    {id, pid} = start_session(tmp, workflow_mode: :exit_normal)
    subscribe(id)

    assert :ok = Server.prompt(pid, "hello")
    {worker, monitor} = await_held_worker(:exit_normal)
    send(worker, :run_boundary_release)

    assert_receive {:agent_event, ^id,
                    %Event.AgentEnd{messages: [%Message.Assistant{stop_reason: :error}]}},
                   1_000

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    _ = :sys.get_state(pid)

    snapshot = Server.state(pid)
    refute snapshot.running
    assert snapshot.run_metadata == nil
    assert [%Message.Assistant{stop_reason: :error} = error] = snapshot.messages
    assert error.error_message =~ "workflow_exit"
  end

  test "an invalid workflow return uses the normalized failure path", %{tmp: tmp} do
    {id, pid} = start_session(tmp, workflow_mode: {:invalid, :not_a_workflow_result})
    subscribe(id)

    assert :ok = Server.prompt(pid, "hello")
    {worker, monitor} = await_held_worker({:invalid, :not_a_workflow_result})
    send(worker, :run_boundary_release)

    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    _ = :sys.get_state(pid)

    snapshot = Server.state(pid)
    refute snapshot.running
    assert [%Message.Assistant{stop_reason: :error} = error] = snapshot.messages
    assert error.error_message =~ "invalid_workflow_result"
  end

  test "metadata promotes only with AgentEnd and a non-error final assistant", %{tmp: tmp} do
    {id, pid} = start_session(tmp, workflow_mode: :success)
    subscribe(id)

    assert :ok = Server.prompt(pid, "first")
    {worker, monitor} = await_held_worker(:success)

    active = Server.state(pid)
    assert active.running
    assert active.run_metadata.prompt.text == "session prompt"
    assert active.run_metadata.context.model_id == "model-a"
    assert active.run_metadata.workflow.module == Catalyst.Test.RunBoundaryWorkflow

    send(worker, :run_boundary_release)
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    _ = :sys.get_state(pid)

    successful = Server.state(pid)
    refute successful.running
    assert successful.run_metadata.context.model_id == "model-a"
    assert successful.run_metadata.prompt.text == "session prompt"

    :ok =
      Server.configure(pid,
        model: model("model-d"),
        opts: [run_boundary_workflow_mode: :agent_end_only]
      )

    assert :ok = Server.prompt(pid, "second")
    {worker, monitor} = await_held_worker(:agent_end_only)
    assert Server.state(pid).run_metadata.context.model_id == "model-d"

    send(worker, :run_boundary_release)
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    _ = :sys.get_state(pid)

    no_final_assistant = Server.state(pid)
    refute no_final_assistant.running
    assert no_final_assistant.run_metadata.context.model_id == "model-a"

    :ok =
      Server.configure(pid,
        model: model("model-b"),
        opts: [run_boundary_workflow_mode: :missing_agent_end]
      )

    assert :ok = Server.prompt(pid, "third")
    {worker, monitor} = await_held_worker(:missing_agent_end)
    assert Server.state(pid).run_metadata.context.model_id == "model-b"

    send(worker, :run_boundary_release)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    _ = :sys.get_state(pid)

    missing_end = Server.state(pid)
    refute missing_end.running
    assert missing_end.run_metadata.context.model_id == "model-a"

    :ok =
      Server.configure(pid,
        model: model("model-c"),
        opts: [run_boundary_workflow_mode: :assistant_error]
      )

    assert :ok = Server.prompt(pid, "fourth")
    {worker, monitor} = await_held_worker(:assistant_error)
    assert Server.state(pid).run_metadata.context.model_id == "model-c"

    send(worker, :run_boundary_release)
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    _ = :sys.get_state(pid)

    assistant_error = Server.state(pid)
    refute assistant_error.running
    assert assistant_error.run_metadata.context.model_id == "model-a"
  end

  test "terminal non-promotable runs expose prior metadata before task cleanup finishes", %{
    tmp: tmp
  } do
    {id, pid} = start_session(tmp, workflow_mode: :success)
    subscribe(id)

    assert :ok = Server.prompt(pid, "baseline")
    {worker, monitor} = await_held_worker(:success)
    send(worker, :run_boundary_release)
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    _ = :sys.get_state(pid)

    :ok =
      Server.configure(pid,
        model: model("model-error"),
        opts: [run_boundary_workflow_mode: :assistant_error_after_end]
      )

    assert :ok = Server.prompt(pid, "error")
    {worker, monitor} = await_held_worker(:assistant_error_after_end)
    send(worker, :run_boundary_release)

    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert_receive {:run_boundary_after_agent_end, ^worker}, 1_000

    terminal_but_active = Server.state(pid)
    assert terminal_but_active.running
    assert terminal_but_active.run_metadata.context.model_id == "model-a"

    send(worker, :run_boundary_finish)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    _ = :sys.get_state(pid)

    settled = Server.state(pid)
    refute settled.running
    assert settled.run_metadata.context.model_id == "model-a"
  end

  test "a submission accepted after AgentEnd starts when task cleanup finishes", %{tmp: tmp} do
    {id, pid} = start_session(tmp, workflow_mode: :assistant_error_after_end)
    subscribe(id)

    assert {:ok, :started} = Server.submit(pid, "first")
    {first_worker, first_monitor} = await_held_worker(:assistant_error_after_end)
    send(first_worker, :run_boundary_release)

    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert_receive {:run_boundary_after_agent_end, ^first_worker}, 1_000
    assert {:ok, :queued} = Server.submit(pid, "queued at completion")

    :ok =
      Server.configure(pid,
        opts: [run_boundary_workflow_mode: :success]
      )

    send(first_worker, :run_boundary_finish)
    assert_receive {:DOWN, ^first_monitor, :process, ^first_worker, :normal}, 1_000

    {second_worker, second_monitor} = await_held_worker(:success)
    send(second_worker, :run_boundary_release)
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert_receive {:DOWN, ^second_monitor, :process, ^second_worker, :normal}, 1_000
    _ = :sys.get_state(pid)

    users = Enum.filter(Server.state(pid).messages, &match?(%Message.User{}, &1))

    assert Enum.map(users, &Catalyst.Content.text_of(&1.content)) == [
             "first",
             "queued at completion"
           ]
  end

  test "normalized guard failures balance observed lifecycle events", %{tmp: tmp} do
    owner = "failure-observer-#{System.unique_integer([:positive])}"
    test_pid = self()

    Hooks.on(fn event -> send(test_pid, {:observed_failure_event, event}) end, owner: owner)
    on_exit(fn -> Hooks.unregister(owner) end)

    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(
        cwd: tmp,
        system_prompt: "session prompt",
        provider: Catalyst.LLM.Faux,
        model: model("guard-failure"),
        tools: [],
        opts: [context_threshold: 1, script: [{:text, "must not run"}]]
      )

    on_exit(fn -> Manager.stop(id) end)
    subscribe(id)

    assert :ok = Server.prompt(pid, "too large")
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert :ok = Hooks.await_observers(id)

    assert_receive {:observed_failure_event, %Event.AgentStart{}}
    assert_receive {:observed_failure_event, %Event.MessageEnd{message: %Message.User{}}}

    assert_receive {:observed_failure_event,
                    %Event.MessageEnd{message: %Message.Assistant{stop_reason: :error}}}

    assert_receive {:observed_failure_event,
                    %Event.AgentEnd{messages: [%Message.Assistant{stop_reason: :error}]}}
  end

  test "abort and reset clear current metadata without promoting it", %{tmp: tmp} do
    {id, pid} = start_session(tmp, workflow_mode: :success)
    subscribe(id)

    assert :ok = Server.prompt(pid, "successful baseline")
    {worker, monitor} = await_held_worker(:success)
    send(worker, :run_boundary_release)
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    _ = :sys.get_state(pid)
    assert Server.state(pid).run_metadata.context.model_id == "model-a"

    :ok = Server.configure(pid, model: model("model-b"))
    assert :ok = Server.prompt(pid, "abort this")
    {worker, monitor} = await_held_worker(:success)
    assert Server.state(pid).run_metadata.context.model_id == "model-b"

    Server.abort(pid)
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    _ = :sys.get_state(pid)
    assert Server.state(pid).run_metadata.context.model_id == "model-a"

    :ok = Server.configure(pid, model: model("model-c"))
    assert :ok = Server.prompt(pid, "reset this")
    {worker, monitor} = await_held_worker(:success)
    assert Server.state(pid).run_metadata.context.model_id == "model-c"

    Server.reset(pid)
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    _ = :sys.get_state(pid)

    reset = Server.state(pid)
    assert reset.messages == []
    assert reset.run_metadata.context.model_id == "model-a"
  end

  defp start_session(tmp, opts) do
    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(
        cwd: tmp,
        system_prompt: "session prompt",
        provider: Catalyst.LLM.Faux,
        model: model("model-a"),
        tools: [],
        opts: [
          loop: Catalyst.Test.RunBoundaryWorkflow,
          run_boundary_test_pid: self(),
          run_boundary_hold: true,
          run_boundary_prompt_mode: Keyword.get(opts, :prompt_mode, :ok),
          run_boundary_workflow_mode: Keyword.fetch!(opts, :workflow_mode)
        ]
      )

    on_exit(fn -> Manager.stop(id) end)
    {id, pid}
  end

  defp subscribe(id), do: Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

  defp await_held_worker(mode) do
    assert_receive {:run_boundary_workflow_started, worker, ^mode}, 1_000
    {worker, Process.monitor(worker)}
  end

  defp model(id) do
    %Model{
      id: id,
      api: "faux",
      provider: "faux",
      context_window: 10_000,
      context_window_source: :session
    }
  end
end
