defmodule CatalystWeb.Flex.UIEverythingFlexTest do
  use CatalystWeb.FlexCase, async: false

  @moduletag :flexibility

  alias Catalyst.{Content, Extensions, Hooks, Message}
  alias CatalystWeb.UI.Registry

  @shell_keys [
    {CatalystWeb.ShellLive, :current_session},
    {CatalystWeb.ShellLive, :codex_prefs},
    {CatalystWeb.ShellLive, :ui_prefs}
  ]

  @tag :git
  test "W3: every owner-aware category composes in one real UI run and reverts", %{conn: conn} do
    install_fixture!("ui_everything")
    previous_provider = with_codex_provider(Catalyst.Ext.UIEverythingProvider)
    previous_loop = with_agent_loop(Catalyst.Ext.UIEverythingLoop)
    previous_prompt = write_system_prompt!("FLEX-EVERYTHING-SYS")
    previous_persistent = snapshot_persistent()
    Enum.each(@shell_keys, &:persistent_term.erase/1)

    assert Extensions.fetch("flex_everything") == {:ok, Catalyst.Ext.UIEverythingTool}
    assert {:ok, Catalyst.Ext.UIEverythingProvider} = Catalyst.LLM.Registry.fetch("ui-everything")
    assert Enum.count(Hooks.handlers(:event), &(&1.owner == "ui_everything")) == 1
    assert {:ok, _page} = Registry.fetch_page("flex-everything")
    assert {:ok, %{owner: "ui_everything"}} = Registry.fetch_command("flex-status")
    assert Enum.any?(Registry.list_renderers(), &(&1.owner == "ui_everything"))
    assert Enum.any?(Registry.list_components(), &(&1.owner == "ui_everything"))

    [process] = Catalyst.Extensions.Processes.list("ui_everything")
    process_ref = Process.monitor(process)

    {:ok, view, _html} = live(conn, ~p"/")
    id = session_id(view)
    assert has_element?(view, "#flex-everything-header")

    submit_prompt!(view, "exercise everything")
    assert has_element?(view, "#flex-everything-card")
    assert latest_assistant_text(view) =~ "[everything-after-hook]"

    await_observers!(id)
    state = apply(Catalyst.Ext.UIEverythingState, :snapshot, []) |> elem(1)

    for key <- [
          :provider,
          :prompt,
          :tool,
          :transform_context,
          :before_tool_call,
          :after_tool_call,
          :prepare_next_turn,
          :should_stop_after_turn,
          :observer
        ] do
      assert Map.get(state, key, 0) > 0, "expected #{key} to participate"
    end

    view
    |> form("#chat-form", %{"message" => "/flex-status"})
    |> render_submit()

    assert render(view) =~ "FLEX-STATUS tool=1 observer="

    view |> element("a", "Everything") |> render_click()
    assert has_element?(view, "#flex-everything-page")
    view |> element("a", "Chat") |> render_click()

    await_observers!(id)
    restore_codex_provider(previous_provider)
    restore_app_env(:catalyst, :agent_loop, previous_loop)
    restore_file(Catalyst.SystemPrompt.path(), previous_prompt)
    restore_persistent_map(previous_persistent)
    remove_installed_fixture!("ui_everything")

    assert_receive {:DOWN, ^process_ref, :process, ^process, _reason}, 1_000
    assert Extensions.fetch("flex_everything") == :error

    assert {:error, {:unknown_api, "ui-everything"}} =
             Catalyst.LLM.Registry.fetch("ui-everything")

    assert :error = Registry.fetch_page("flex-everything")
    assert :error = Registry.fetch_command("flex-status")

    _new_id = fresh_session!(view)
    submit_prompt!(view, "list files")
    refute render(view) =~ "FLEX-EVERYTHING"

    restore_persistent_map(previous_persistent)
  end

  defp latest_assistant_text(view) do
    view
    |> session_pid()
    |> Catalyst.Session.Server.state()
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
