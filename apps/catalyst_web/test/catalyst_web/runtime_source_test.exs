defmodule CatalystWeb.RuntimeSourceTest do
  use ExUnit.Case, async: false

  alias Catalyst.Runtime.Context
  alias CatalystWeb.RuntimeSource

  test "exports web registry contributions without introducing service claims" do
    assert {:ok, snapshot} = RuntimeSource.snapshot(Context.new(%{}))
    assert snapshot.claims == []
    assert snapshot.metadata.ui_layers == :effective_and_additive_entries

    assert Enum.any?(snapshot.contributions, fn contribution ->
             contribution.point == "ui.page" and contribution.id == "chat" and
               contribution.owner == :builtin
           end)

    assert Enum.any?(snapshot.contributions, fn contribution ->
             contribution.point == "ui.command" and contribution.id == "cd"
           end)
  end
end
