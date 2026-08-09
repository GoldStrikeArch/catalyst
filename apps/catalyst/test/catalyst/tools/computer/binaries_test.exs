defmodule Catalyst.Tools.Computer.BinariesTest do
  # async: false — Binaries caches successful resolutions in :persistent_term.
  use ExUnit.Case, async: false

  alias Catalyst.Tools.Binaries

  test "catalyst-input resolves through the shared Binaries order" do
    assert :catalyst_input in Binaries.tools()

    # Whether the helper is built on this machine or not, the resolution
    # contract holds: a found binary ends in the exe name, and a missing one
    # hints at the build task (never `brew install` — it is built, not brewed).
    case Binaries.path(:catalyst_input) do
      {:ok, path} ->
        assert String.ends_with?(path, "catalyst-input")

      {:error, {:missing, :catalyst_input, hint}} ->
        assert hint =~ "mix catalyst.computer.build"
        refute hint =~ "brew install"
    end
  end

  test "unknown tools stay tagged errors" do
    assert {:error, {:unknown_tool, :nope}} = Binaries.path(:nope)
  end
end
