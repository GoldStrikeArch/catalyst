defmodule Catalyst.Workflow.Runner do
  @moduledoc """
  Runs one pinned workflow template through the durable workflow coordinator.

  Each stage executes in a fresh child session. Only the original user goal and
  explicitly connected artifacts cross stage boundaries.
  """

  @behaviour Catalyst.Workflow

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message}
  alias Catalyst.Session.Store.Codec
  alias Catalyst.Workflow.Template

  @impl true
  def run(prompts, context, config, emit) do
    emit.(%Event.AgentStart{})
    Enum.each(prompts, &emit.(%Event.MessageEnd{message: &1}))

    with {:ok, template} <- selected_template(config),
         {:ok, goal} <- goal(prompts),
         {:ok, id, supervisor} <- start_run(template, goal, config) do
      monitor = Process.monitor(supervisor)

      try do
        await(id, monitor, supervisor, template, prompts, context, config, emit)
      after
        Process.demonitor(monitor, [:flush])
        cancel_if_running(id)
      end
    end
  end

  defp selected_template(%{workflow: %{template: %Template{} = template}}),
    do: {:ok, template}

  defp selected_template(config), do: {:error, {:missing_workflow_template, config[:workflow]}}

  defp goal(prompts) do
    text =
      prompts
      |> Enum.map_join("\n\n", fn
        %Message.User{content: content} -> Content.text_of(content)
        message -> inspect(message)
      end)

    case String.trim(text) do
      "" -> {:error, :blank_workflow_goal}
      goal -> {:ok, goal}
    end
  end

  defp start_run(template, goal, config) do
    id = "workflow_" <> Catalyst.Ids.hex(16)

    input = %{
      "goal" => goal,
      "cwd" => config.cwd,
      "model" => Codec.encode_model(config.model),
      "parent_session_id" => config.parent_session_id,
      "root_session_id" => config.root_session_id,
      "reasoning_effort" => config.opts[:reasoning_effort],
      "transport" => stringify(config.opts[:transport]),
      "service_tier" => stringify(config.opts[:service_tier]),
      "template_snapshot" => Template.snapshot(template)
    }

    stages = template |> Template.to_map() |> Map.fetch!("stages")

    with :ok <- Catalyst.WorkflowRun.subscribe(id),
         {:ok, run} <-
           Catalyst.WorkflowRun.start(id: id, stages: stages, input: input, owner: self()) do
      {:ok, id, run.pid}
    else
      {:error, reason} -> {:error, {:workflow_run_start, reason}}
    end
  end

  defp await(id, monitor, supervisor, template, prompts, context, config, emit) do
    receive do
      {:workflow_run_event, ^id, %{"type" => "attempt_started", "context" => attempt}} ->
        stage = attempt["stage"]

        emit.(%Event.WorkflowStageStart{
          id: stage["id"],
          name: stage["name"],
          index: attempt["stage_index"],
          total: length(template.stages),
          attempt: attempt["attempt"]
        })

        await(id, monitor, supervisor, template, prompts, context, config, emit)

      {:workflow_run_event, ^id, %{"type" => "stage_completed"} = event} ->
        stage = event["stage"]

        emit.(%Event.WorkflowStageEnd{
          id: stage["id"],
          name: stage["name"],
          index: event["stage_index"],
          total: event["total_stages"],
          status: :completed
        })

        await(id, monitor, supervisor, template, prompts, context, config, emit)

      {:workflow_run_event, ^id, %{"type" => "completed", "checkpoint" => checkpoint}} ->
        finish(checkpoint, prompts, context, config, emit)

      {:workflow_run_event, ^id, %{"type" => status, "checkpoint" => checkpoint}}
      when status in ["failed", "cancelled"] ->
        {:error, {:workflow_run_failed, status, checkpoint["error"] || checkpoint["reason"]}}

      {:workflow_run_event, ^id, _progress} ->
        await(id, monitor, supervisor, template, prompts, context, config, emit)

      {:DOWN, ^monitor, :process, ^supervisor, reason} ->
        finish_after_down(id, reason, prompts, context, config, emit)
    end
  end

  defp finish_after_down(id, reason, prompts, context, config, emit) do
    case Catalyst.WorkflowRun.get(id) do
      {:ok, %{"status" => "completed"} = checkpoint} ->
        finish(checkpoint, prompts, context, config, emit)

      {:ok, %{"status" => status} = checkpoint} when status in ["failed", "cancelled"] ->
        {:error, {:workflow_run_failed, status, checkpoint["error"] || checkpoint["reason"]}}

      _missing_or_running ->
        {:error, {:workflow_run_down, reason}}
    end
  end

  defp finish(checkpoint, prompts, context, config, emit) do
    result = List.last(checkpoint["results"] || [])
    text = result && result["artifact"]

    case is_binary(text) and String.trim(text) != "" do
      true ->
        assistant = %Message.Assistant{
          content: Content.text(text),
          model: config.model && config.model.id,
          stop_reason: :stop,
          timestamp: Message.now()
        }

        emit.(%Event.MessageEnd{message: assistant})
        messages = prompts ++ [assistant]
        emit.(%Event.AgentEnd{messages: messages})
        {:ok, messages, %{context | messages: context.messages ++ messages}}

      false ->
        {:error, :workflow_missing_final_artifact}
    end
  end

  defp cancel_if_running(id) do
    case Catalyst.WorkflowRun.get(id) do
      {:ok, %{"status" => "running"}} -> Catalyst.WorkflowRun.cancel(id, "parent run stopped")
      _terminal_or_missing -> :ok
    end
  end

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)
end
