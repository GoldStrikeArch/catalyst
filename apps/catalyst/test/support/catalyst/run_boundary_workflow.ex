defmodule Catalyst.Test.RunBoundaryWorkflow do
  @moduledoc false

  @behaviour Catalyst.Workflow

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message}

  @impl true
  def run(prompts, context, config, emit) do
    mode = Keyword.get(config.opts, :run_boundary_workflow_mode, :success)

    sync_server(config)
    notify_started(config, mode)
    await_release(config)
    finish(mode, prompts, context, config, emit)
  end

  defp finish({:error, reason}, _prompts, _context, _config, _emit),
    do: {:error, reason}

  defp finish({:invalid, value}, _prompts, _context, _config, _emit), do: value
  defp finish(:exit_normal, _prompts, _context, _config, _emit), do: exit(:normal)

  defp finish(:agent_end_only, prompts, context, _config, emit) do
    Enum.each(prompts, &emit.(%Event.MessageEnd{message: &1}))
    emit.(%Event.AgentEnd{messages: prompts})
    {:ok, [], %{context | messages: context.messages ++ prompts}}
  end

  defp finish(mode, prompts, context, config, emit) do
    Enum.each(prompts, &emit.(%Event.MessageEnd{message: &1}))

    assistant = assistant(mode, config.model)
    emit.(%Event.MessageEnd{message: assistant})

    case mode do
      :missing_agent_end -> :ok
      _other -> emit.(%Event.AgentEnd{messages: prompts ++ [assistant]})
    end

    hold_after_agent_end(mode, config)
    {:ok, [assistant], %{context | messages: context.messages ++ prompts ++ [assistant]}}
  end

  defp assistant(mode, model) when mode in [:assistant_error, :assistant_error_after_end] do
    %Message.Assistant{
      content: Content.text("workflow assistant error"),
      model: model_id(model),
      stop_reason: :error,
      error_message: "workflow assistant error",
      timestamp: Message.now()
    }
  end

  defp assistant(_mode, model) do
    %Message.Assistant{
      content: Content.text("workflow success"),
      model: model_id(model),
      stop_reason: :stop,
      timestamp: Message.now()
    }
  end

  defp sync_server(config) do
    case Map.get(config, :get_steering) do
      fun when is_function(fun, 0) -> fun.()
      _none -> :ok
    end
  end

  defp notify_started(config, mode) do
    case Keyword.get(config.opts, :run_boundary_test_pid) do
      pid when is_pid(pid) -> send(pid, {:run_boundary_workflow_started, self(), mode})
      _none -> :ok
    end
  end

  defp hold_after_agent_end(:assistant_error_after_end, config) do
    case Keyword.get(config.opts, :run_boundary_test_pid) do
      pid when is_pid(pid) -> send(pid, {:run_boundary_after_agent_end, self()})
      _none -> :ok
    end

    receive do
      :run_boundary_finish -> :ok
    end
  end

  defp hold_after_agent_end(_mode, _config), do: :ok

  defp await_release(config) do
    case Keyword.get(config.opts, :run_boundary_hold, false) do
      true ->
        receive do
          :run_boundary_release -> :ok
        end

      false ->
        :ok
    end
  end

  defp model_id(nil), do: nil
  defp model_id(model), do: model.id
end
