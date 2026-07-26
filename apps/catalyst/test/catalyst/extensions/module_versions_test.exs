defmodule Catalyst.Extensions.ModuleVersionsTest do
  use ExUnit.Case, async: false

  alias Catalyst.Extensions.ModuleVersions

  @module Catalyst.Test.ModuleVersionsProbe

  setup do
    on_exit(fn -> ModuleVersions.restore_original(@module) end)
    :ok
  end

  test "put replaces an owner's prior entries and owner_beams returns exact binaries" do
    beam_v1 = compile_beam(1)
    beam_v2 = compile_beam(2)

    versions =
      %{}
      |> ModuleVersions.put("alpha", "alpha-v1.ex", %{@module => beam_v1})
      |> ModuleVersions.put("beta", "beta.ex", %{@module => beam_v2})
      |> ModuleVersions.put("alpha", "alpha-v2.ex", %{@module => beam_v2})

    assert {:ok, %{@module => ^beam_v2}} =
             ModuleVersions.owner_beams([@module], "alpha", versions)

    assert {:ok, %{@module => ^beam_v2}} =
             ModuleVersions.owner_beams([@module], "beta", versions)

    assert :error = ModuleVersions.owner_beams([@module], "missing", versions)

    assert [%{owner: "alpha", path: "alpha-v2.ex"}, %{owner: "beta", path: "beta.ex"}] =
             versions[@module]
  end

  test "dropping the active owner restores the previous accepted binary" do
    beam_v1 = compile_beam(1)
    beam_v2 = compile_beam(2)

    old_versions =
      %{}
      |> ModuleVersions.put("first", "first.ex", %{@module => beam_v1})
      |> ModuleVersions.put("second", "second.ex", %{@module => beam_v2})

    assert apply(@module, :value, []) == 2

    new_versions = ModuleVersions.drop_owner(old_versions, "second")
    assert :ok = ModuleVersions.restore_removed(@module, "second", old_versions, new_versions)
    assert apply(@module, :value, []) == 1

    assert :ok = ModuleVersions.restore_removed(@module, "first", new_versions, %{})
    refute Code.ensure_loaded?(@module)
  end

  test "a non-active owner removal leaves the current module untouched" do
    beam_v1 = compile_beam(1)
    beam_v2 = compile_beam(2)

    old_versions =
      %{}
      |> ModuleVersions.put("first", "first.ex", %{@module => beam_v1})
      |> ModuleVersions.put("second", "second.ex", %{@module => beam_v2})

    new_versions = ModuleVersions.drop_owner(old_versions, "first")
    assert :ok = ModuleVersions.restore_removed(@module, "first", old_versions, new_versions)
    assert apply(@module, :value, []) == 2
  end

  defp compile_beam(value) do
    source = """
    defmodule #{@module} do
      def value, do: #{value}
    end
    """

    options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      [{@module, beam}] = Code.compile_string(source, "module_versions_#{value}.ex")
      beam
    after
      Code.compiler_options(options)
    end
  end
end
