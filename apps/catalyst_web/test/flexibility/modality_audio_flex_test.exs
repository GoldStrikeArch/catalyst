defmodule Catalyst.Flex.UnknownContentBlock do
  @moduledoc false
  defstruct [:data]
end

defmodule CatalystWeb.Flex.ModalityAudioFlexTest do
  use CatalystWeb.FlexCase, async: false

  @moduletag :flexibility

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message, Model}
  alias Catalyst.LLM.Context
  alias Catalyst.LLM.OpenAICodex.Request
  alias Catalyst.Session.Server
  alias CatalystWeb.UI.MessageRenderer

  test "W4: audio uses details plus a runtime renderer; unknown user blocks degrade safely", %{
    conn: conn
  } do
    refute Code.ensure_loaded?(Catalyst.Content.Audio)
    refute Code.ensure_loaded?(Catalyst.Content.Video)

    vision = %Model{id: "vision", api: "openai-codex-responses", input: [:text, :image]}

    request =
      Request.build(
        vision,
        %Context{
          messages: [
            %Message.User{
              content: [
                %Content.Text{text: "describe"},
                %Content.Image{data: "QUJD", mime_type: "image/png"}
              ]
            }
          ],
          tools: []
        }
      )

    assert [%{"content" => parts}] = request["input"]
    assert Enum.map(parts, & &1["type"]) == ["input_text", "input_image"]

    unknown_details = %Message.ToolResult{
      tool_call_id: "unknown-details",
      tool_name: "unknown_details",
      content: Content.text("BUILT-IN-FALLBACK"),
      details: %{future_modality: %{kind: "hologram"}}
    }

    fallback_html =
      unknown_details
      |> then(&MessageRenderer.render_message(%{msg: &1}))
      |> rendered_to_string()

    assert fallback_html =~ ~s(data-message-role="tool-result")
    assert fallback_html =~ "BUILT-IN-FALLBACK"

    install_fixture!("ui_audio_probe")
    previous_provider = with_codex_provider(Catalyst.Ext.UIAudioProvider)

    {:ok, view, _html} = live(conn, ~p"/legacy-chat")
    id = session_id(view)

    submit_prompt!(view, "prepare audio")
    assert has_element?(view, "#flex-audio-card")
    assert has_element?(view, ~s(#flex-audio-player[src^="data:audio/wav;base64,"]))

    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    :ok =
      Server.prompt(session_pid(view), [
        %Content.Text{text: "unknown-block-probe"},
        %Catalyst.Flex.UnknownContentBlock{data: "AAAA"}
      ])

    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 5_000

    assert has_element?(
             view,
             "#message-stream",
             "FLEX-UNKNOWN-REQUEST types=input_text text=unknown-block-probe"
           )

    restore_codex_provider(previous_provider)
    remove_installed_fixture!("ui_audio_probe")

    _new_id = fresh_session!(view)
    submit_prompt!(view, "list files")
    refute has_element?(view, "#flex-audio-card")
  end
end
