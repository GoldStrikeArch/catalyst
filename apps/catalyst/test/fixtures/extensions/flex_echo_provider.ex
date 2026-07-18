defmodule Catalyst.Ext.FlexEchoProvider do
  @moduledoc false

  @behaviour Catalyst.LLM.Provider

  alias Catalyst.{Content, Message}
  alias Catalyst.LLM.Event

  @impl true
  def stream(model, context, _opts, sink) do
    text = scripted_text(context) || default_text(context)
    assistant = assistant(model, text)

    sink.(%Event.TextStart{})
    sink.(%Event.TextDelta{delta: text})
    sink.(%Event.TextEnd{})

    {:ok, assistant}
  end

  defp scripted_text(context) do
    case Application.get_env(:catalyst, :flex_echo_script) do
      fun when is_function(fun, 1) -> fun.(context)
      text when is_binary(text) -> text
      _other -> nil
    end
  end

  defp default_text(context) do
    system = context.system_prompt |> to_string() |> String.split("\n") |> List.first()

    user =
      context.messages
      |> Enum.reverse()
      |> Enum.find_value("", fn
        %Message.User{content: content} -> Content.text_of(content)
        _message -> false
      end)

    "[flex-echo] sys=#{system} user=#{user}"
  end

  defp assistant(model, text) do
    %Message.Assistant{
      content: Content.text(text),
      api: "flex-echo",
      provider: "flex-echo",
      model: model.id,
      stop_reason: :stop,
      timestamp: Message.now()
    }
  end
end

defmodule Catalyst.Ext.FlexEchoExtension do
  @moduledoc false

  use Catalyst.Extension

  @impl true
  def setup(api) do
    Catalyst.ExtensionAPI.register_provider(
      api,
      "flex-echo",
      %Catalyst.LLM.ProviderConfig{
        module: Catalyst.Ext.FlexEchoProvider,
        name: "Flex Echo"
      }
    )
  end
end
