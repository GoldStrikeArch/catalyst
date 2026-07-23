defmodule CatalystWeb.Flex.UIProviderLoopFlexTest do
  use CatalystWeb.FlexCase, async: false

  @moduletag :flexibility

  alias Catalyst.{Content, Message}
  alias Catalyst.Session.Server

  @shell_keys [
    {CatalystWeb.ShellLive, :current_session},
    {CatalystWeb.ShellLive, :codex_prefs},
    {CatalystWeb.ShellLive, :ui_prefs}
  ]

  test "W2: stock Codex UI composes provider injection, model data, and a custom loop", %{
    conn: conn
  } do
    load_fixture!("flex_echo_provider")
    load_fixture!("flex_loop")

    previous_provider = with_codex_provider(Catalyst.Ext.FlexEchoProvider)

    assert {:ok, Catalyst.Ext.FlexEchoProvider} =
             Catalyst.LLM.Registry.fetch("openai-codex-responses")

    previous_loop = with_agent_loop(Catalyst.Ext.FlexLoop)

    previous_models =
      with_codex_models(
        [
          %{id: "flex-model-a", name: "Flex Model A", efforts: ~w(low high)},
          %{id: "flex-model-b", name: "Flex Model B", efforts: ~w(low medium high)}
        ],
        "flex-model-a"
      )

    previous_persistent = snapshot_persistent()
    Enum.each(@shell_keys, &:persistent_term.erase/1)

    {:ok, view, _html} = live(conn, ~p"/")
    pid = session_pid(view)

    assert has_element?(view, ~s(#codex-opts option[value="flex-model-a"]))
    assert has_element?(view, ~s(#codex-opts option[value="flex-model-b"]))

    view
    |> form("#codex-opts")
    |> render_change(%{
      "model" => "flex-model-b",
      "effort" => "high",
      "transport" => "auto"
    })

    assert Server.state(pid).model.id == "flex-model-b"

    submit_prompt!(view, "hello from the UI")
    assert latest_assistant_text(pid) =~ "[flex-loop] [flex-echo]"

    restore_codex_provider(previous_provider)
    restore_app_env(:catalyst, :agent_loop, previous_loop)
    restore_app_env(:catalyst, :codex_models, previous_models.codex_models)
    restore_app_env(:catalyst, :codex_model, previous_models.codex_model)
    restore_persistent_map(previous_persistent)
    unload_fixture!("flex_loop")
    unload_fixture!("flex_echo_provider")

    _new_id = fresh_session!(view)
    submit_prompt!(view, "list files")

    assert has_element?(view, "#message-stream", "offline Demo provider")
    refute has_element?(view, "#catalyst-shell", "[flex-loop]")
    refute has_element?(view, "#catalyst-shell", "[flex-echo]")

    restore_persistent_map(previous_persistent)
  end

  defp latest_assistant_text(pid) do
    pid
    |> Server.state()
    |> Map.fetch!(:messages)
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message.Assistant{content: content} -> Content.text_of(content)
      _message -> false
    end)
  end

  defp snapshot_persistent do
    Map.new(@shell_keys, fn key -> {key, persistent_snapshot(key)} end)
  end

  defp restore_persistent_map(snapshot) do
    Enum.each(snapshot, fn {key, value} -> restore_persistent(key, value) end)
  end
end
