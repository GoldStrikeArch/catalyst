defmodule CatalystWeb.RuntimeSourceTest do
  use ExUnit.Case, async: false

  alias Catalyst.Runtime.Context
  alias CatalystWeb.{RuntimeSource, Workbench}

  test "exports web contributions and the built-in workbench claim" do
    assert {:ok, snapshot} = RuntimeSource.snapshot(Context.new(%{}))
    assert snapshot.metadata.ui_layers == :effective_and_additive_entries

    assert Enum.any?(snapshot.claims, fn claim ->
             claim.key == Workbench.key() and claim.owner == :builtin
           end)

    assert Enum.any?(snapshot.contributions, fn contribution ->
             contribution.point == "ui.page" and contribution.id == "chat" and
               contribution.owner == :builtin
           end)

    assert Enum.any?(snapshot.contributions, fn contribution ->
             contribution.point == "ui.command" and contribution.id == "cd"
           end)
  end
end
