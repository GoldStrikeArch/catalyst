defmodule Catalyst.Extensions.ModulesTest do
  use ExUnit.Case, async: false

  alias Catalyst.Extensions.Modules

  @module Catalyst.Test.ExtensionModulesProbe

  setup do
    on_exit(fn -> Modules.restore_original(@module) end)
    :ok
  end

  test "loads each staged binary exactly" do
    beam_v1 = compile_beam(1)
    assert :ok = Modules.load("extension_modules_v1.ex", %{@module => beam_v1})
    assert apply(@module, :value, []) == 1

    beam_v2 = compile_beam(2)
    assert :ok = Modules.load("extension_modules_v2.ex", %{@module => beam_v2})
    assert apply(@module, :value, []) == 2

    refute beam_v1 == beam_v2
  end

  test "restoring a source-only module removes it from the live VM" do
    _beam = compile_beam(:temporary)
    assert Code.ensure_loaded?(@module)

    assert :ok = Modules.restore_original(@module)
    refute Code.ensure_loaded?(@module)
  end

  defp compile_beam(value) do
    source = """
    defmodule #{@module} do
      def value, do: #{inspect(value)}
    end
    """

    options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      [{@module, beam}] = Code.compile_string(source, "extension_modules_#{value}.ex")
      beam
    after
      Code.compiler_options(options)
    end
  end
end
