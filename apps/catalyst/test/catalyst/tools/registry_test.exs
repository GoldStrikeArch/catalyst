defmodule Catalyst.Tools.RegistryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import ExUnit.CaptureIO, only: [with_io: 2]

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

  defmodule RaisingMode do
    def name, do: "raising_mode"
    def description, do: "raises while declaring its execution mode"
    def parameters, do: %{"type" => "object"}
    def execution_mode, do: raise("mode failed")
    def execute(_args, _ctx), do: :ok
  end

  defmodule HangingMode do
    def name, do: "hanging_mode"
    def description, do: "hangs while declaring its execution mode"
    def parameters, do: %{"type" => "object"}

    def execution_mode do
      receive do
        :never -> :parallel
      end
    end

    def execute(_args, _ctx), do: :ok
  end

  defmodule DeclaredCapabilities do
    use Catalyst.Tools.Tool

    @impl true
    def name, do: "declared_capabilities"
    @impl true
    def description, do: "declares a capability"
    @impl true
    def parameters, do: %{"type" => "object"}
    @impl true
    def capabilities, do: [:computer_use]
    @impl true
    def execute(_args, _ctx), do: result("ok")
  end

  defmodule BadCapabilities do
    def name, do: "bad_capabilities"
    def description, do: "declares capabilities that are not atoms"
    def parameters, do: %{"type" => "object"}
    def capabilities, do: ["computer_use"]
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

  test "index/1 maps every tool name to its validated entry" do
    index = Registry.index(Registry.default_tools())

    assert map_size(index) == length(Registry.default_tools())

    assert Enum.all?(Registry.default_tools(), fn module ->
             entry = index[module.name()]
             entry.module == module and entry.definition.name == module.name()
           end)
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

    assert {:error, {:bad_tool_mode, "mode failed"}} = Registry.definition(RaisingMode)

    assert {:error, {:tool_metadata_timeout, HangingMode}} =
             Registry.definition(HangingMode, timeout: 10)
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

    assert %{"registry_fixture" => %{module: ^module}} = Registry.index([module])
    assert [%{name: "registry_fixture"}] = Registry.to_provider_tools([module])
    refute_receive {:metadata_callback, _callback}, 0

    Registry.invalidate(module)
    assert [%{name: "registry_fixture"}] = Registry.to_provider_tools([module])
    assert_receive {:metadata_callback, :name}
    assert_receive {:metadata_callback, :description}
    assert_receive {:metadata_callback, :parameters}
  end

  test "entries carry a resolved schema and fetch/2 keeps returning the module" do
    index = Registry.index([Catalyst.Tools.Read])

    assert {:ok,
            %{
              module: Catalyst.Tools.Read,
              fingerprint: fingerprint,
              definition: %{execution_mode: :parallel},
              resolved_schema: {:ok, %ExJsonSchema.Schema.Root{}},
              executor: executor
            }} = Registry.fetch_entry(index, "read")

    assert is_binary(fingerprint)
    assert is_function(executor, 2)
    assert {:ok, Catalyst.Tools.Read} = Registry.fetch(index, "read")
  end

  test "a hot reload refreshes both execution mode and resolved schema" do
    module = Catalyst.Test.ReloadedRegistryTool

    on_exit(fn ->
      Registry.invalidate(module)
      :code.purge(module)
      :code.delete(module)
    end)

    compile_reloadable_tool(:sequential, "text")

    assert {:ok,
            %{
              definition: %{execution_mode: :sequential},
              resolved_schema: {:ok, first_schema},
              executor: :external
            } = first_entry} = Registry.cached_entry(module)

    assert Registry.entry_current?(first_entry)
    assert :ok = ExJsonSchema.Validator.validate(first_schema, %{"text" => "ok"})
    assert {:error, _errors} = ExJsonSchema.Validator.validate(first_schema, %{})

    compile_reloadable_tool(:parallel, "count")

    refute Registry.entry_current?(first_entry)

    assert {:error, {:stale_tool_entry, ^module}} =
             Registry.execution_target(first_entry)

    assert {:ok,
            %{
              definition: %{execution_mode: :parallel},
              resolved_schema: {:ok, reloaded_schema}
            }} = Registry.cached_entry(module)

    assert :ok = ExJsonSchema.Validator.validate(reloaded_schema, %{"count" => "ok"})
    assert {:error, _errors} = ExJsonSchema.Validator.validate(reloaded_schema, %{})
  end

  test "capabilities are validated into the cached definition and served from it" do
    on_exit(fn -> Registry.invalidate(DeclaredCapabilities) end)

    assert {:ok, %{capabilities: [:computer_use]}} = Registry.definition(DeclaredCapabilities)
    assert Registry.capabilities_of(DeclaredCapabilities) == [:computer_use]

    # Tools that never declare any: the default from `use Catalyst.Tools.Tool`
    # and a plain module without the callback both read as ungated.
    assert Registry.capabilities_of(Catalyst.Tools.Read) == []
    assert {:ok, %{capabilities: []}} = Registry.definition(Catalyst.Tools.Read)
  end

  test "a malformed capability list makes the tool unavailable rather than ungated" do
    assert {:error, {:bad_tool_capabilities, ["computer_use"]}} =
             Registry.definition(BadCapabilities)

    assert Registry.capabilities_of(BadCapabilities) == []

    log = capture_log(fn -> assert Registry.index([BadCapabilities]) == %{} end)
    assert log =~ "metadata unavailable"
  end

  test "a hot reload revalidates capabilities like the rest of the metadata" do
    module = Catalyst.Test.CapabilityRegistryTool

    on_exit(fn ->
      Registry.invalidate(module)
      :code.purge(module)
      :code.delete(module)
    end)

    compile_capability_tool("[:computer_use]")
    assert Registry.capabilities_of(module) == [:computer_use]

    compile_capability_tool("[]")
    assert Registry.capabilities_of(module) == []
  end

  defp compile_capability_tool(capabilities) do
    source = """
    defmodule Catalyst.Test.CapabilityRegistryTool do
      def name, do: "capability_registry_tool"
      def description, do: "capability metadata probe"
      def parameters, do: %{"type" => "object"}
      def capabilities, do: #{capabilities}
      def execute(_args, _context), do: %{content: [], details: %{}, terminate: false}
    end
    """

    {_compiled, _stderr} = with_io(:stderr, fn -> Code.compile_string(source) end)
    :ok
  end

  defp compile_reloadable_tool(mode, required) do
    source = """
    defmodule Catalyst.Test.ReloadedRegistryTool do
      def name, do: "reloaded_registry_tool"
      def description, do: "reload metadata probe"
      def parameters do
        %{
          "type" => "object",
          "properties" => %{#{inspect(required)} => %{"type" => "string"}},
          "required" => [#{inspect(required)}]
        }
      end
      def execution_mode, do: #{inspect(mode)}
      def execute(_args, _context), do: %{content: [], details: %{}, terminate: false}
    end
    """

    {_compiled, _stderr} = with_io(:stderr, fn -> Code.compile_string(source) end)
    :ok
  end
end
