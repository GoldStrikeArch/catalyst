defmodule Catalyst.IdsTest do
  use ExUnit.Case, async: true

  test "hex returns lowercase, fixed-width random identifiers" do
    first = Catalyst.Ids.hex(8)
    second = Catalyst.Ids.hex(8)

    assert first =~ ~r/^[0-9a-f]{16}$/
    assert second =~ ~r/^[0-9a-f]{16}$/
    refute first == second
  end
end
