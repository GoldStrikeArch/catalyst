defmodule Catalyst.Workflow.RunnerTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message, Model}
  alias Catalyst.Workflow.{Runner, Template}

  defmodule Attempt do
    @behaviour Catalyst.WorkflowRun.Attempt

    @impl true
    def run(context, _emit) do
      controller = Process.whereis(Catalyst.Workflow.RunnerTest)
      send(controller, {:runner_attempt, self(), context})

      receive do
        {:return, result} -> result
      end
    end
  end

  setup do
    Process.register(self(), __MODULE__)

    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_workflow_runner_#{System.unique_integer([:positive, :monotonic])}"
      )

    previous_root = Application.fetch_env(:catalyst, :workflow_runs_root)
    previous_attempt = Application.fetch_env(:catalyst, :workflow_run_attempt_module)

    Application.put_env(:catalyst, :workflow_runs_root, root)
    Application.put_env(:catalyst, :workflow_run_attempt_module, Attempt)

    on_exit(fn ->
      restore_env(:workflow_runs_root, previous_root)
      restore_env(:workflow_run_attempt_module, previous_attempt)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "connects a pinned template to durable stages and the parent response" do
    test = self()
    config = config(template())
    prompt = Message.user("Ship the change")
    context = %{system_prompt: nil, messages: []}
    emit = fn event -> send(test, {:runner_event, event}) end

    start_supervised!(
      {Task,
       fn ->
         send(test, {:runner_result, Runner.run([prompt], context, config, emit)})
       end}
    )

    assert_receive {:runner_event, %Event.AgentStart{}}, 2_000
    assert_receive {:runner_event, %Event.MessageEnd{message: ^prompt}}, 2_000

    assert_receive {:runner_attempt, research, research_context}, 2_000
    assert research_context["stage"]["id"] == "research"
    send(research, {:return, {:ok, %{"artifact_id" => "research", "artifact" => "handoff"}}})

    assert_receive {:runner_attempt, reviewer, review_context}, 2_000
    assert review_context["stage"]["id"] == "review"

    assert review_context["results"] == [
             %{"artifact_id" => "research", "artifact" => "handoff"}
           ]

    send(reviewer, {:return, {:ok, %{"artifact_id" => "review", "artifact" => "approved"}}})

    assert_receive {:runner_result, {:ok, [^prompt, assistant], final_context}}, 2_000
    assert Content.text_of(assistant.content) == "approved"
    assert final_context.messages == [prompt, assistant]

    assert_receive {:runner_event, %Event.AgentEnd{messages: [^prompt, ^assistant]}}, 2_000
  end

  defp config(template) do
    %{
      workflow: %{template: template},
      cwd: System.tmp_dir!(),
      model: %Model{id: "faux", api: "faux"},
      parent_session_id: "parent",
      root_session_id: "root",
      opts: []
    }
  end

  defp template do
    {:ok, template} =
      Template.new(%{
        "version" => 1,
        "id" => "runner-test",
        "name" => "Runner test",
        "description" => "Exercises the durable runner bridge.",
        "stages" => [
          stage("research", "research", "inspect", ["goal"], "research"),
          stage("review", "code_review", "inspect", ["goal"], "review")
        ]
      })

    template
  end

  defp stage(id, preset, profile, inputs, artifact) do
    %{
      "id" => id,
      "name" => String.capitalize(id),
      "prompt" => "Complete the stage.",
      "preset" => preset,
      "tool_profile" => profile,
      "model" => "inherit",
      "reasoning_effort" => "high",
      "inputs" => inputs,
      "artifact" => artifact,
      "inactivity_timeout_ms" => 30_000,
      "timeout_ms" => 60_000,
      "max_attempts" => 3
    }
  end
end
