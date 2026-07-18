defmodule Catalyst.Ext.FlexLoop do
  @moduledoc false

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Extensions, Message}
  alias Catalyst.LLM.Context
  alias Catalyst.Tools.Registry

  @doc false
  @spec run([Message.t()], map(), map(), (Event.t() -> term())) :: {:ok, [Message.t()], map()}
  def run(prompts, context, config, emit) do
    emit.(%Event.AgentStart{})
    Enum.each(prompts, &emit.(%Event.MessageEnd{message: &1}))

    messages = context.messages ++ prompts

    llm_context = %Context{
      system_prompt: context.system_prompt,
      messages: messages,
      tools: config.tools |> Extensions.resolve() |> Registry.to_provider_tools()
    }

    {:ok, assistant} =
      config.provider.stream(config.model, llm_context, config.opts, fn _ -> :ok end)

    assistant = prepend_marker(assistant)
    emit.(%Event.MessageEnd{message: assistant})

    emitted = prompts ++ [assistant]
    emit.(%Event.AgentEnd{messages: emitted})
    {:ok, emitted, %{context | messages: messages ++ [assistant]}}
  end

  defp prepend_marker(%Message.Assistant{} = assistant) do
    %{assistant | content: [%Content.Text{text: "[flex-loop] "} | assistant.content]}
  end
end
