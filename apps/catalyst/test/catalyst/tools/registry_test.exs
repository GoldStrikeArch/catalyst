defmodule Catalyst.Tools.RegistryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Catalyst.Tools.Registry

  defmodule MissingDescription do
    def name, do: "missing_description"
    def parameters, do: %{"type" => "object"}
    def execute(_args, _ctx), do: :ok
  end

  defmodule RaisingDescription do
    def name, do: "raising_description"
    def description, do: raise("description failed")
    def parameters, do: %{"type" => "object"}
    def execute(_args, _ctx), do: :ok
  end

  defmodule HangingParameters do
    def name, do: "hanging_parameters"
    def description, do: "hangs"

    def parameters do
      receive do
        :never -> %{}
      end
    end

    def execute(_args, _ctx), do: :ok
  end

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

  test "definition rejects missing, raising, and hanging metadata callbacks" do
    assert {:error, {:not_a_tool, MissingDescription}} = Registry.definition(MissingDescription)

    assert {:error, {:bad_tool_description, "description failed"}} =
             Registry.definition(RaisingDescription)

    assert {:error, {:tool_metadata_timeout, HangingParameters}} =
             Registry.definition(HangingParameters, timeout: 10)
  end

  test "provider serialization skips invalid tool modules" do
    log =
      capture_log(fn ->
        assert [%{name: "read"}] =
                 Registry.to_provider_tools([
                   Catalyst.Tools.Read,
                   MissingDescription,
                   RaisingDescription
                 ])
      end)

    assert log =~ "metadata unavailable"
    assert log =~ inspect(MissingDescription)
    assert log =~ inspect(RaisingDescription)
  end

  test "turn lookups reuse registration metadata without invoking callbacks" do
    module = Catalyst.Test.RegistryTool
    observer_key = {module, :observer}
    :persistent_term.put(observer_key, self())
    Registry.invalidate(module)

    on_exit(fn ->
      :persistent_term.erase(observer_key)
      Registry.invalidate(module)
    end)

    assert {:ok, %{name: "registry_fixture"}} = Registry.definition(module)
    assert_receive {:metadata_callback, :name}
    assert_receive {:metadata_callback, :description}
    assert_receive {:metadata_callback, :parameters}

    assert %{"registry_fixture" => ^module} = Registry.index([module])
    assert [%{name: "registry_fixture"}] = Registry.to_provider_tools([module])
    refute_receive {:metadata_callback, _callback}, 0

    Registry.invalidate(module)
    assert [%{name: "registry_fixture"}] = Registry.to_provider_tools([module])
    assert_receive {:metadata_callback, :name}
    assert_receive {:metadata_callback, :description}
    assert_receive {:metadata_callback, :parameters}
  end
end
