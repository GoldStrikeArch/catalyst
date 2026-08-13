defmodule Catalyst.Workflow.AttemptTest do
  use ExUnit.Case, async: false

  alias Catalyst.Agent.Event
  alias Catalyst.Message
  alias Catalyst.Workflow.Attempt

  defmodule FakeSession do
    @behaviour Catalyst.Workflow.Attempt.SessionAdapter

    @impl true
    def start_fresh(opts), do: start(:fresh, opts)

    @impl true
    def resume(opts), do: start(:resume, opts)

    @impl true
    def subscribe(id), do: call_controller({:subscribe, id}, :ok)

    @impl true
    def unsubscribe(id), do: call_controller({:unsubscribe, id}, :ok)

    @impl true
    def prompt(pid, prompt), do: call_controller({:prompt, pid, prompt}, :ok)

    @impl true
    def abort(pid), do: call_controller({:abort, pid}, :ok)

    @impl true
    def stop(id), do: call_controller({:stop, id}, :ok)

    defp start(mode, opts) do
      child = spawn(fn -> child_loop() end)
      call_controller({:start, mode, opts, child}, {:ok, %{id: opts[:id], pid: child}})
    end

    defp child_loop do
      receive do
        :stop -> :ok
      end
    end

    defp call_controller(message, default) do
      controller = Application.fetch_env!(:catalyst, :attempt_test_controller)
      send(controller, {:fake_session, self(), message})

      receive do
        {:fake_session_reply, reply} -> reply
      after
        100 -> default
      end
    end
  end

  setup do
    previous = Application.fetch_env(:catalyst, :attempt_test_controller)
    Application.put_env(:catalyst, :attempt_test_controller, self())

    on_exit(fn ->
      case previous do
        {:ok, controller} ->
          Application.put_env(:catalyst, :attempt_test_controller, controller)

        :error ->
          Application.delete_env(:catalyst, :attempt_test_controller)
      end
    end)

    :ok
  end

  test "fresh attempt isolates prompt and strips the parent workflow" do
    {:ok, worker} =
      start_supervised(
        {Attempt,
         attempt_opts(
           goal: "Review the patch",
           artifacts: %{"patch" => "change.diff"},
           opts: [workflow: "parent-template", loop: ParentWorkflow, reasoning_effort: :high]
         )}
      )

    assert_receive {:fake_session, starter, {:start, :fresh, opts, child}}
    assert opts[:id] =~ ~r/\Aparent_w[0-9a-f]{32}\z/
    assert opts[:cwd] == "/workspace"
    assert opts[:parent_id] == "parent"
    assert opts[:root_session_id] == "root"
    assert opts[:opts] == [reasoning_effort: :high]
    refute Keyword.has_key?(opts, :workflow)
    send(starter, {:fake_session_reply, {:ok, %{id: opts[:id], pid: child}}})

    assert_receive {:fake_session, subscriber, {:subscribe, child_id}}
    send(subscriber, {:fake_session_reply, :ok})

    assert_receive {:fake_session, prompter, {:prompt, ^child, prompt}}
    assert prompt =~ "Goal:\nReview the patch"
    assert prompt =~ ~s("patch": "change.diff")
    refute prompt =~ "parent-template"
    send(prompter, {:fake_session_reply, :ok})

    assert_receive {:workflow_attempt, ^worker,
                    {:started, %{child_session_id: ^child_id, resumed: false}}}

    send(worker, {:agent_event, child_id, %Event.TurnStart{}})

    assert_receive {:workflow_attempt, ^worker,
                    {:activity, %{child_session_id: ^child_id, event: "turn_start"}}}

    finish(worker, child_id, "approved")
    assert_receive {:workflow_attempt, ^worker, {:finished, {:ok, result}}}
    assert result.artifact == "approved"
    assert result.child_session_id == child_id
    assert result.incomplete == false
  end

  test "retry resumes exactly the supplied child session id" do
    {:ok, worker} = start_supervised({Attempt, attempt_opts(session_id: "stage-child")})

    assert_receive {:fake_session, starter, {:start, :resume, opts, child}}
    assert opts[:id] == "stage-child"
    send(starter, {:fake_session_reply, {:ok, %{id: "stage-child", pid: child}}})
    allow_prompt("stage-child", child)

    assert_receive {:workflow_attempt, ^worker,
                    {:started, %{child_session_id: "stage-child", resumed: true}}}

    finish(worker, "stage-child", "retry result")
    assert_receive {:workflow_attempt, ^worker, {:finished, {:ok, _result}}}
  end

  test "inactivity aborts the child and reports a recoverable failure" do
    {:ok, worker} =
      start_supervised({Attempt, attempt_opts(inactivity_timeout: 30, hard_timeout: 5_000)})

    {child_id, child} = allow_start_and_prompt()
    assert_receive {:workflow_attempt, ^worker, {:started, _details}}

    assert_receive {:fake_session, aborter, {:abort, ^child}}, 500
    send(aborter, {:fake_session_reply, :ok})

    assert_receive {:workflow_attempt, ^worker,
                    {:finished,
                     {:error,
                      %{
                        class: :recoverable,
                        reason: :inactivity_timeout,
                        child_session_id: ^child_id
                      }}}}
  end

  test "explicit abort leaves retry policy with the coordinator" do
    {:ok, worker} = start_supervised({Attempt, attempt_opts()})
    {_child_id, child} = allow_start_and_prompt()
    assert_receive {:workflow_attempt, ^worker, {:started, _details}}

    :ok = Attempt.abort(worker)
    assert_receive {:fake_session, aborter, {:abort, ^child}}
    send(aborter, {:fake_session_reply, :ok})

    assert_receive {:workflow_attempt, ^worker,
                    {:finished, {:error, %{class: :recoverable, reason: :aborted}}}}
  end

  test "hard deadline is independent from activity" do
    {:ok, worker} =
      start_supervised({Attempt, attempt_opts(inactivity_timeout: 5_000, hard_timeout: 30)})

    {child_id, child} = allow_start_and_prompt()
    assert_receive {:workflow_attempt, ^worker, {:started, _details}}
    send(worker, {:agent_event, child_id, %Event.TurnStart{}})
    assert_receive {:workflow_attempt, ^worker, {:activity, _details}}

    assert_receive {:fake_session, aborter, {:abort, ^child}}, 500
    send(aborter, {:fake_session_reply, :ok})

    assert_receive {:workflow_attempt, ^worker,
                    {:finished,
                     {:error,
                      %{
                        class: :recoverable,
                        reason: :hard_timeout,
                        child_session_id: ^child_id
                      }}}}
  end

  test "hard deadline reaps a child returned after startup cancellation" do
    {:ok, worker} =
      start_supervised({Attempt, attempt_opts(inactivity_timeout: 5_000, hard_timeout: 30)})

    assert_receive {:fake_session, starter, {:start, :fresh, opts, child}}
    child_id = opts[:id]

    assert_receive {:workflow_attempt, ^worker,
                    {:finished,
                     {:error,
                      %{
                        class: :recoverable,
                        reason: :hard_timeout,
                        child_session_id: nil
                      }}}},
                   500

    send(starter, {:fake_session_reply, {:ok, %{id: child_id, pid: child}}})
    assert_receive {:fake_session, stopper, {:stop, ^child_id}}, 500
    send(stopper, {:fake_session_reply, :ok})
    refute_receive {:fake_session, _, {:prompt, _, _}}
  end

  test "bounds the final artifact and rejects terminal malformed input" do
    {:ok, worker} =
      start_supervised({Attempt, attempt_opts(max_artifact_bytes: 512)})

    {child_id, _child} = allow_start_and_prompt()
    assert_receive {:workflow_attempt, ^worker, {:started, _details}}
    finish(worker, child_id, String.duplicate("🙂", 400))

    assert_receive {:workflow_attempt, ^worker, {:finished, {:ok, result}}}
    assert String.valid?(result.artifact)
    assert byte_size(result.artifact) <= 512
    assert result.truncated

    assert {:error, {{:invalid_goal, "  "}, _child_spec}} =
             start_supervised(
               {Attempt, attempt_opts(goal: "  ")},
               id: {:invalid_attempt, make_ref()}
             )

    assert Attempt.classify_error({:child_provider_error, "overloaded"}) == :recoverable
    assert Attempt.classify_error({:invalid_artifacts, :bad}) == :terminal
  end

  test "length-limited output is recoverable instead of advancing a workflow" do
    {:ok, worker} = start_supervised({Attempt, attempt_opts()})
    {child_id, _child} = allow_start_and_prompt()
    assert_receive {:workflow_attempt, ^worker, {:started, _details}}

    assistant = %Message.Assistant{
      content: Catalyst.Content.text("partial"),
      stop_reason: :length
    }

    send(worker, {:agent_event, child_id, %Event.AgentEnd{messages: [assistant]}})

    assert_receive {:workflow_attempt, ^worker,
                    {:finished,
                     {:error,
                      %{
                        class: :recoverable,
                        reason: :child_incomplete_assistant,
                        child_session_id: ^child_id
                      }}}}
  end

  defp attempt_opts(overrides \\ []) do
    defaults = [
      owner: self(),
      goal: "Implement the stage",
      artifacts: [],
      cwd: "/workspace",
      model: %{id: "model"},
      provider: FakeProvider,
      parent_id: "parent",
      root_session_id: "root",
      opts: [],
      inactivity_timeout: 5_000,
      hard_timeout: 10_000,
      session_adapter: FakeSession
    ]

    Keyword.merge(defaults, overrides)
  end

  defp allow_start_and_prompt do
    assert_receive {:fake_session, starter, {:start, :fresh, opts, child}}
    child_id = opts[:id]
    send(starter, {:fake_session_reply, {:ok, %{id: child_id, pid: child}}})
    allow_prompt(child_id, child)
    {child_id, child}
  end

  defp allow_prompt(child_id, child) do
    assert_receive {:fake_session, subscriber, {:subscribe, ^child_id}}
    send(subscriber, {:fake_session_reply, :ok})
    assert_receive {:fake_session, prompter, {:prompt, ^child, _prompt}}
    send(prompter, {:fake_session_reply, :ok})
  end

  defp finish(worker, child_id, text) do
    assistant = %Message.Assistant{content: Catalyst.Content.text(text), stop_reason: :stop}
    send(worker, {:agent_event, child_id, %Event.AgentEnd{messages: [assistant]}})
  end
end
