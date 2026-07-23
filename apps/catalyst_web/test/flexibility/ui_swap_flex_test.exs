defmodule CatalystWeb.Flex.UISwapFlexTest do
  use CatalystWeb.FlexCase, async: false

  @moduletag :flexibility

  alias CatalystWeb.UI.Registry

  test "W1: page, renderer, command, and component swap together and revert", %{
    conn: conn,
    flex_baseline: baseline,
    flex_home: home
  } do
    File.write!(Path.join(home, "ui-known.txt"), "known")
    install_fixture!("ui_chat_page")
    install_fixture!("ui_renderer_pack")

    Baseline.assert_dimensions_unchanged!(baseline, [
      :tools,
      :providers,
      :hooks,
      :extension_processes
    ])

    {:ok, view, _html} = live(conn, ~p"/")
    _session_id = session_id(view)

    assert has_element?(view, "#flex-chat-v2")
    assert has_element?(view, "#flex-header-widget")

    submit_prompt!(view, "list the current directory")
    assert has_element?(view, ~s([data-flex-renderer="ls"]))

    view
    |> form("#chat-form", %{"message" => "/flexping hello"})
    |> render_submit()

    assert has_element?(view, "#flash-info", "FLEX-PONG hello")

    remove_installed_fixture!("ui_renderer_pack")
    remove_installed_fixture!("ui_chat_page")

    assert {:ok, {CatalystWeb.Pages.ChatPage, :render}} = Registry.fetch_page("chat")
    assert {:ok, %{owner: nil}} = Registry.fetch_command("cd")
    assert :error = Registry.fetch_command("flexping")

    {:ok, baseline_view, _html} = live(conn, ~p"/")
    _baseline_id = session_id(baseline_view)

    refute has_element?(baseline_view, "#flex-chat-v2")
    refute has_element?(baseline_view, "#flex-header-widget")

    submit_prompt!(baseline_view, "list the current directory")
    assert has_element?(baseline_view, ~s([data-message-role="tool-result"]))
    refute has_element?(baseline_view, ~s([data-flex-renderer="ls"]))
  end

  test "W5: a whole-shell module shadow applies only to a fresh mount and restores", %{conn: conn} do
    original_hash = object_code_hash(CatalystWeb.ShellLive)
    load_fixture!("ui_shell_shadow")

    {:ok, _shadow_view, shadow_html} = live(conn, ~p"/")
    assert shadow_html =~ "FLEX-SHELL-SHADOW"

    unload_fixture!("ui_shell_shadow")
    assert object_code_hash(CatalystWeb.ShellLive) == original_hash

    {:ok, restored_view, _html} = live(conn, ~p"/")
    _session_id = session_id(restored_view)

    assert has_element?(restored_view, "#catalyst-shell")
    refute has_element?(restored_view, "#flex-shell-shadow")
  end

  defp object_code_hash(module) do
    {^module, binary, _path} = :code.get_object_code(module)
    :crypto.hash(:sha256, binary)
  end
end
