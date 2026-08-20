defmodule Catalyst.Test.BlockingWorkflow do
  @moduledoc false

  @behaviour Catalyst.Workflow

  alias Catalyst.Agent.Event
  alias Catalyst.Content
  alias Catalyst.Message

  @impl true
  def provider_required?, do: false

  @impl true
  def run(prompts, context, config, emit) do
    test_pid = Keyword.fetch!(config.opts, :blocking_test_pid)
    ref = Keyword.fetch!(config.opts, :blocking_ref)
    send(test_pid, {:blocking_workflow_started, ref, self()})

    receive do
      {:release_blocking_workflow, ^ref} -> finish(prompts, context, emit)
    end
  end

  defp finish(prompts, context, emit) do
    assistant = %Message.Assistant{
      content: Content.text("released"),
      stop_reason: :stop,
      timestamp: Message.now()
    }

    messages = prompts ++ [assistant]
    emit.(%Event.AgentStart{})
    Enum.each(messages, &emit.(%Event.MessageEnd{message: &1}))
    emit.(%Event.AgentEnd{messages: messages})
    {:ok, messages, %{context | messages: context.messages ++ messages}}
  end
end
