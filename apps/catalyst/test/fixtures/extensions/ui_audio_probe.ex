defmodule Catalyst.Ext.UIAudioTool do
  @moduledoc false

  use Catalyst.Tools.Tool

  @audio_base64 "UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA="

  @impl true
  def name, do: "flex_audio"

  @impl true
  def description, do: "Return an audio payload in tool details for a runtime UI renderer."

  @impl true
  def parameters,
    do: %{"type" => "object", "properties" => %{}, "required" => []}

  @impl true
  def execute(_args, _ctx) do
    result("FLEX-AUDIO-READY", %{
      audio: %{mime_type: "audio/wav", data: @audio_base64}
    })
  end
end

defmodule Catalyst.Ext.UIAudioProvider do
  @moduledoc false

  @behaviour Catalyst.LLM.Provider

  alias Catalyst.{Content, Message}
  alias Catalyst.LLM.Event
  alias Catalyst.LLM.OpenAICodex.Request

  @impl true
  def stream(model, context, _opts, sink) do
    assistant = response(model, context)
    emit(assistant.content, sink)
    {:ok, assistant}
  end

  defp response(model, context) do
    case List.last(context.messages) do
      %Message.ToolResult{tool_name: "flex_audio"} = result ->
        text_message(model, "[audio-provider] complete " <> Content.text_of(result.content))

      %Message.User{} = user ->
        case Content.text_of(user.content) do
          "unknown-block-probe" -> request_probe(model, context)
          _text -> tool_message(model)
        end

      _message ->
        tool_message(model)
    end
  end

  defp request_probe(model, context) do
    body = Request.build(model, context, [])

    parts =
      body["input"]
      |> Enum.reverse()
      |> Enum.find_value([], fn
        %{"role" => "user", "content" => content} -> content
        _item -> false
      end)

    types = Enum.map_join(parts, ",", & &1["type"])
    text = Enum.find_value(parts, "", & &1["text"])
    text_message(model, "FLEX-UNKNOWN-REQUEST types=#{types} text=#{text}")
  end

  defp tool_message(model) do
    %Message.Assistant{
      content: [
        %Content.Text{text: "[audio-provider] preparing audio"},
        %Content.ToolCall{id: "flex_audio_call", name: "flex_audio", arguments: %{}}
      ],
      api: "flex-audio",
      provider: "flex-audio",
      model: model.id,
      stop_reason: :tool_use,
      timestamp: Message.now()
    }
  end

  defp text_message(model, text) do
    %Message.Assistant{
      content: Content.text(text),
      api: "flex-audio",
      provider: "flex-audio",
      model: model.id,
      stop_reason: :stop,
      timestamp: Message.now()
    }
  end

  defp emit(blocks, sink) do
    Enum.each(blocks, fn
      %Content.Text{text: text} ->
        sink.(%Event.TextStart{})
        sink.(%Event.TextDelta{delta: text})
        sink.(%Event.TextEnd{})

      %Content.ToolCall{id: id, name: name, arguments: arguments} ->
        sink.(%Event.ToolCallStart{id: id, name: name})
        sink.(%Event.ToolCallEnd{id: id, name: name, arguments: arguments})

      _block ->
        :ok
    end)
  end
end

defmodule Catalyst.Ext.UIAudioProbe do
  @moduledoc false

  use Catalyst.Extension
  use CatalystWeb, :html

  alias Catalyst.ExtensionAPI
  alias Catalyst.LLM.ProviderConfig
  alias Catalyst.Message

  @impl true
  def setup(api) do
    :ok =
      ExtensionAPI.register_provider(
        api,
        "flex-audio",
        %ProviderConfig{module: Catalyst.Ext.UIAudioProvider, name: "Flex Audio"}
      )

    ExtensionAPI.register_renderer(
      api,
      :message,
      &__MODULE__.audio_result?/1,
      &__MODULE__.render_audio/1
    )
  end

  @doc false
  def audio_result?(%Message.ToolResult{
        tool_name: "flex_audio",
        details: %{audio: %{mime_type: mime_type, data: data}}
      })
      when is_binary(mime_type) and is_binary(data),
      do: true

  def audio_result?(_message), do: false

  @doc false
  def render_audio(assigns) do
    audio = assigns.msg.details.audio
    assigns = Map.put(assigns, :audio, audio)

    ~H"""
    <article id="flex-audio-card" data-flex-renderer="audio">
      <strong>FLEX-AUDIO-CARD</strong>
      <audio
        id="flex-audio-player"
        controls
        preload="none"
        src={"data:#{@audio.mime_type};base64,#{@audio.data}"}
      >
      </audio>
    </article>
    """
  end
end
