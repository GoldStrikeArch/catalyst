defmodule CatalystDesktop.MenuBarTest do
  use ExUnit.Case, async: true

  # handle_event("quit", _) is deliberately untested: it ends in
  # Desktop.Window.quit/0, which halts the VM.

  test "renders menu XML the Desktop.Menu parser accepts" do
    xml = CatalystDesktop.MenuBar.render(%{})

    assert xml =~ ~s(<item onclick="quit">)

    # Round-trip through the dep's strict parser — it requires <menubar> as
    # the literal ROOT token, which is why the render must stay a plain
    # string: dev's debug_heex_annotations prepend an HTML comment to every
    # ~H template, and the parse failure leaves the menu empty (regression
    # dumped to parse_error.xml at the repo root). On failure parse/1
    # returns [], so this match catches it.
    assert {:menubar, _attrs, [{:menu, _menu_attrs, _items}]} =
             Desktop.Menu.Parser.parse(xml)
  end

  test "mount passes assigns through" do
    assert {:ok, %{probe: 1}} = CatalystDesktop.MenuBar.mount(%{probe: 1})
  end
end
