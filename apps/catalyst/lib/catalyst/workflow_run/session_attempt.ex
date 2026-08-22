defmodule Catalyst.WorkflowRun.SessionAttempt do
  @moduledoc """
  Bridges a durable workflow-run attempt to one isolated child session.

  The coordinator owns retry decisions. This adapter starts the asynchronous
  `Catalyst.Workflow.Attempt`, forwards activity, and converts its terminal
  result into the JSON-safe synchronous attempt contract.
  """

  @behaviour Catalyst.WorkflowRun.Attempt

  alias Catalyst.Session.Store.Codec
  alias Catalyst.LLM.Models
  alias Catalyst.Workflow.Attempt

  @impl true
  def run(context, emit) do
    Process.flag(:trap_exit, true)

    with {:ok, opts} <- attempt_options(context),
         {:ok, worker} <- Attempt.start_link(opts) do
      monitor = Process.monitor(worker)
      await(worker, monitor, context["stage"], emit)
    else
      {:error, reason} -> {:retry, json_failure(reason)}
    end
  end

  defp await(worker, monitor, stage, emit) do
    receive do
      {:workflow_attempt, ^worker, {:started, details}} ->
        emit.(Map.put(stringify(details), "type", "started"))
        await(worker, monitor, stage, emit)

      {:workflow_attempt, ^worker, {:activity, details}} ->
        emit.(Map.put(stringify(details), "type", "activity"))
        await(worker, monitor, stage, emit)

      {:workflow_attempt, ^worker, {:finished, {:ok, result}}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, success(stage, result)}

      {:workflow_attempt, ^worker, {:finished, {:error, failure}}} ->
        Process.demonitor(monitor, [:flush])
        classify(failure)

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        {:retry, %{"attempt_worker_exit" => inspect(reason)}}

      {:EXIT, ^worker, _reason} ->
        await(worker, monitor, stage, emit)
    end
  end

  defp attempt_options(%{"input" => input, "stage" => stage} = context) do
    with {:ok, model} <- model(stage, input),
         {:ok, goal} <- stage_goal(stage, input),
         {:ok, artifacts} <- artifacts(stage, context["results"]) do
      {:ok,
       [
         owner: self(),
         goal: goal,
         artifacts: artifacts,
         cwd: input["cwd"],
         model: model,
         provider: model.api,
         session_id: context["stage_session_id"],
         parent_id: input["parent_session_id"],
         root_session_id: input["root_session_id"],
         tools: :extensions,
         opts: stage_opts(stage, input),
         system_prompt: system_prompt(stage),
         inactivity_timeout: stage["inactivity_timeout_ms"],
         hard_timeout: stage["timeout_ms"]
       ]}
    end
  end

  defp attempt_options(context), do: {:error, {:invalid_attempt_context, context}}

  defp model(%{"model" => selected}, input) when is_binary(selected) and selected != "inherit" do
    case Models.resolve(selected) do
      {:ok, {_provider_id, model}} -> {:ok, model}
      {:error, {:unknown_model, ^selected}} -> build_from_input_provider(selected, input)
      {:error, _reason} = error -> error
    end
  end

  defp model(_stage, %{"model" => encoded}) do
    case Codec.decode_model(encoded) do
      {:ok, model} -> {:ok, model}
      :error -> {:error, :invalid_workflow_model}
    end
  end

  defp build_from_input_provider(selected, %{"model" => encoded}) do
    with {:ok, inherited} <- Codec.decode_model(encoded),
         {:ok, provider_id} <- Models.provider_id(inherited),
         {:ok, {_provider_id, model}} <- Models.resolve(provider_id, selected) do
      {:ok, model}
    else
      :error -> {:error, :invalid_workflow_model}
      {:error, _reason} = error -> error
    end
  end

  defp stage_goal(stage, %{"goal" => goal}) when is_binary(goal) do
    {:ok, "Stage instructions:\n#{stage["prompt"]}\n\nOriginal goal:\n#{goal}"}
  end

  defp stage_goal(_stage, input), do: {:error, {:invalid_workflow_goal, input["goal"]}}

  defp artifacts(stage, results) when is_list(results) do
    wanted = MapSet.new(stage["inputs"] || [])

    artifacts =
      results
      |> Enum.filter(&MapSet.member?(wanted, &1["artifact_id"]))
      |> Map.new(&{&1["artifact_id"], &1["artifact"]})

    {:ok, artifacts}
  end

  defp artifacts(_stage, results), do: {:error, {:invalid_workflow_results, results}}

  defp stage_opts(stage, input) do
    effort =
      case stage["reasoning_effort"] do
        "inherit" -> input["reasoning_effort"]
        selected -> selected
      end

    [
      reasoning_effort: effort,
      transport: input["transport"],
      service_tier: input["service_tier"],
      tool_profile: stage["tool_profile"]
    ]
  end

  defp system_prompt(stage) do
    Catalyst.SystemPrompt.default() <>
      "\n\nYou are the isolated #{stage["preset"]} stage of a durable workflow. " <>
      "Follow the stage instructions exactly. Do not assume access to any other agent's transcript."
  end

  defp success(stage, result) do
    %{
      "artifact_id" => stage["artifact"],
      "artifact" => result.artifact,
      "child_session_id" => result.child_session_id,
      "stop_reason" => to_string(result.stop_reason),
      "incomplete" => result.incomplete,
      "truncated" => result.truncated
    }
  end

  defp classify(%{class: :recoverable} = failure), do: {:retry, json_failure(failure)}
  defp classify(failure), do: {:error, json_failure(failure)}

  defp json_failure(%{} = failure) do
    %{
      "reason" => inspect(Map.get(failure, :reason, failure)),
      "child_session_id" => Map.get(failure, :child_session_id)
    }
  end

  defp json_failure(reason), do: %{"reason" => inspect(reason)}
  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
