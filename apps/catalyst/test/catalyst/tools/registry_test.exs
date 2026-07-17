defmodule Catalyst.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias Catalyst.Tools.Registry

  test "fetch/2 returns {:ok, module} for a known name and :error for an unknown one" do
    tools = Registry.default_tools()

    assert {:ok, Catalyst.Tools.Read} = Registry.fetch(tools, "read")
    assert :error = Registry.fetch(tools, "no_such_tool")
  end

  test "fetch/2 accepts a prebuilt index map" do
    index = Registry.index(Registry.default_tools())

    assert {:ok, Catalyst.Tools.Bash} = Registry.fetch(index, "bash")
    assert :error = Registry.fetch(index, "no_such_tool")
  end

  test "index/1 maps every tool name to its module" do
    index = Registry.index(Registry.default_tools())

    assert map_size(index) == length(Registry.default_tools())
    assert Enum.all?(Registry.default_tools(), &(index[&1.name()] == &1))
  end

  test "to_provider_tools/1 serializes name, description, and parameters" do
    [tool | _] = Registry.to_provider_tools(Registry.default_tools())

    assert %{name: name, description: desc, parameters: params} = tool
    assert is_binary(name) and is_binary(desc) and is_map(params)
  end
end
