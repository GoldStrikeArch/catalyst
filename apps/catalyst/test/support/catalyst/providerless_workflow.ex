defmodule Catalyst.Test.ProviderlessWorkflow do
  @moduledoc false

  @behaviour Catalyst.Workflow

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message}

  @impl true
  def provider_required?, do: false

  @impl true
  def run(prompts, context, config, emit) do
    emit.(%Event.AgentStart{})
    Enum.each(prompts, &emit.(%Event.MessageEnd{message: &1}))
    send(config.opts[:providerless_test_pid], {:providerless_config, config.provider})

    assistant = %Message.Assistant{
      content: Content.text("providerless"),
      api: "fixture",
      provider: "fixture",
      timestamp: Message.now()
    }

    messages = prompts ++ [assistant]
    emit.(%Event.MessageEnd{message: assistant})
    emit.(%Event.AgentEnd{messages: messages})

    {:ok, messages, %{context | messages: context.messages ++ messages}}
  end
end
