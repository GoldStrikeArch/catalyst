defmodule Catalyst.ExtensionsTest do
  # async: false — Extensions is global, shared, mutable state.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Catalyst.{Content, Hooks, Message, Model}
  alias Catalyst.Agent.Loop
  alias Catalyst.Extensions
  alias Catalyst.Tools.DevelopTool

  setup do
    File.mkdir_p!(Extensions.dir())
    on_exit(fn -> File.rm_rf!(Extensions.dir()) end)
    :ok
  end

  @shout_source ~S'''
  defmodule Catalyst.Ext.ShoutTest do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "shout_test"
    @impl true
    def description, do: "Uppercases the given text."
    @impl true
    def parameters do
      %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]}
    end
    @impl true
    def execute(%{"text" => t}, _ctx), do: result(String.upcase(t))
  end
  '''

  test "the built-ins (incl. develop_tool) are seeded" do
    assert Extensions.fetch("read")
    assert Extensions.fetch("develop_tool") == DevelopTool
    assert "ast_grep" in Extensions.names()
  end

  test "develop_tool compiles and loads a new tool at runtime (no restart)" do
    ctx = %{cwd: System.tmp_dir!(), call_id: "t", report: fn _ -> :ok end}

    capture_log(fn ->
      DevelopTool.execute(%{"name" => "shout_test", "source" => @shout_source}, ctx)
    end)

    # The freshly written module is now a live, registered tool.
    mod = Extensions.fetch("shout_test")
    assert mod == Catalyst.Ext.ShoutTest
    assert mod.execute(%{"text" => "hi"}, ctx).content |> hd() |> Map.get(:text) == "HI"
  end

  test "the agent can self-develop a tool and use it in the same run" do
    tmp = Path.join(System.tmp_dir!(), "selfdev_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    model = %Model{id: "faux", api: "faux", provider: "faux"}

    # Turn 1: write the tool. Turn 2: call it (now resolvable). Turn 3: done.
    script = [
      {:tool, "develop_tool", %{"name" => "shout_run", "source" => shout_run_source()}},
      {:tool, "shout_run", %{"text" => "it works"}},
      {:text, "self-extended!"}
    ]

    config = %{
      provider: Catalyst.LLM.Faux,
      model: model,
      cwd: tmp,
      # :extensions → the loop resolves the LIVE tool set every turn
      tools: :extensions,
      opts: [script: script]
    }

    {:ok, collector} = Agent.start_link(fn -> [] end)
    emit = fn ev -> Agent.update(collector, &[ev | &1]) end

    {:ok, messages, _ctx} =
      Loop.run(
        [Message.user("extend yourself")],
        %{system_prompt: nil, messages: []},
        config,
        emit
      )

    Agent.stop(collector)

    tool_results = Enum.filter(messages, &match?(%Message.ToolResult{}, &1))
    shout_result = Enum.find(tool_results, &(&1.tool_name == "shout_run"))

    assert shout_result, "expected the self-created tool to have been called"
    assert Content.text_of(shout_result.content) == "IT WORKS"
    assert Content.text_of(List.last(messages).content) == "self-extended!"
  end

  @multikind_source ~S'''
  defmodule Catalyst.Ext.MultiKindTool do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "mk_tool"
    @impl true
    def description, do: "multi-kind test tool"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx), do: result("ok")
  end

  defmodule Catalyst.Ext.MultiKind do
    use Catalyst.Extension
    @impl true
    def setup(api) do
      Catalyst.ExtensionAPI.register_hook(api, :before_tool_call, &Catalyst.Ext.MultiKind.gate/1)
      :ok
    end
    def gate(_ctx), do: :cont
  end
  '''

  test "an extension's setup/1 registers both a tool and a loop hook" do
    on_exit(fn -> Extensions.uninstall("multikind") end)
    path = write_ext("multikind", @multikind_source)

    assert {:ok, summary} = Extensions.load_file(path)
    assert "mk_tool" in summary.tools

    assert Extensions.fetch("mk_tool") == Catalyst.Ext.MultiKindTool
    assert length(owner_hooks("multikind")) == 1
  end

  test "reloading an extension purges its prior hooks (no duplicates)" do
    on_exit(fn -> Extensions.uninstall("multikind") end)
    path = write_ext("multikind", @multikind_source)

    Extensions.load_file(path)
    Extensions.load_file(path)

    assert length(owner_hooks("multikind")) == 1
  end

  # Defined here (not in the extension source) so registration can only come
  # from the extension's setup/1 call, not from file-level auto-classification.
  defmodule SetupOnlyTool do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "setup_only_tool"
    @impl true
    def description, do: "registered from setup/1"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx), do: result("ok")
  end

  @setup_reg_source ~S'''
  defmodule Catalyst.Ext.SetupReg do
    use Catalyst.Extension
    @impl true
    def setup(api) do
      {:ok, _} = Catalyst.ExtensionAPI.register_tool(api, Catalyst.ExtensionsTest.SetupOnlyTool)
      :ok
    end
  end
  '''

  test "setup/1 can register a tool through the API without deadlocking the server" do
    on_exit(fn -> Extensions.uninstall("setupreg") end)
    path = write_ext("setupreg", @setup_reg_source)

    assert {:ok, summary} = Extensions.load_file(path)
    assert summary.extensions == [Catalyst.Ext.SetupReg]
    assert Extensions.fetch("setup_only_tool") == SetupOnlyTool

    # The setup-registered tool is owner-tracked, so uninstall removes it.
    Extensions.uninstall("setupreg")
    assert Extensions.fetch("setup_only_tool") == nil
  end

  @ephemeral_source ~S'''
  defmodule Catalyst.Ext.EphemeralTool do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "ephemeral_tool"
    @impl true
    def description, do: "test tool"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx), do: result("ok")
  end
  '''

  test "load_all purges contributions whose source file was removed (rollback path)" do
    path = write_ext("ephemeral", @ephemeral_source)

    assert {:ok, _} = Extensions.load_file(path)
    assert Extensions.fetch("ephemeral_tool")

    # A rollback (or manual delete) removes the file; reload must deactivate it.
    File.rm!(path)
    capture_log(fn -> Extensions.load_all() end)
    assert Extensions.fetch("ephemeral_tool") == nil
  end

  test "purging an extension removes its modules from the VM" do
    source = ~S'''
    defmodule Catalyst.Ext.VanishingTool do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: "vanishing_tool"
      @impl true
      def description, do: "test tool"
      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
      @impl true
      def execute(_args, _ctx), do: result("ok")
    end
    '''

    path = write_ext("vanishing", source)
    assert {:ok, _} = Extensions.load_file(path)
    assert Code.ensure_loaded?(Catalyst.Ext.VanishingTool)

    File.rm!(path)
    capture_log(fn -> Extensions.load_all() end)

    # Not just unregistered — the module itself is gone from the VM.
    refute Code.ensure_loaded?(Catalyst.Ext.VanishingTool)
    assert Extensions.fetch("vanishing_tool") == nil
  end

  test "purging an extension that shadowed a module restores the original beam" do
    # Put an "original" beam on the code path, as the release's ebin would be.
    tmp_ebin =
      Path.join(System.tmp_dir!(), "catalyst_shadow_ebin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_ebin)

    [{mod, bin}] =
      capture_log_compile(~S'''
      defmodule Catalyst.Ext.Shadowed do
        def version, do: :original
      end
      ''')

    File.write!(Path.join(tmp_ebin, "Elixir.Catalyst.Ext.Shadowed.beam"), bin)
    true = :code.add_patha(String.to_charlist(tmp_ebin))

    on_exit(fn ->
      :code.del_path(String.to_charlist(tmp_ebin))
      File.rm_rf!(tmp_ebin)
      :code.purge(mod)
      :code.delete(mod)
    end)

    assert Catalyst.Ext.Shadowed.version() == :original

    # An extension redefines (shadows) it...
    path =
      write_ext("shadower", ~S'''
      defmodule Catalyst.Ext.Shadowed do
        def version, do: :shadowed
      end
      ''')

    capture_log(fn -> assert {:ok, _} = Extensions.load_file(path) end)
    assert Catalyst.Ext.Shadowed.version() == :shadowed

    # ...and removing the extension restores the original code, not just the registry.
    File.rm!(path)
    capture_log(fn -> Extensions.load_all() end)
    assert Catalyst.Ext.Shadowed.version() == :original
  end

  test "reloading the same file keeps its modules (no restore-clobber mid-reload)" do
    on_exit(fn -> Extensions.uninstall("multikind") end)
    path = write_ext("multikind", @multikind_source)

    capture_log(fn ->
      Extensions.load_file(path)
      Extensions.load_file(path)
    end)

    assert Extensions.fetch("mk_tool") == Catalyst.Ext.MultiKindTool
    assert Catalyst.Ext.MultiKindTool.execute(%{}, %{}).content
  end

  defp capture_log_compile(source) do
    # Code.compile_string warns when redefining across runs; keep logs quiet.
    import ExUnit.CaptureIO
    {result, _io} = with_io(:stderr, fn -> Code.compile_string(source) end)
    result
  end

  test "a broken extension file registers nothing and returns an error" do
    source = ~S'''
    defmodule Catalyst.Ext.BrokenTool do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: "broken_tool"
      this is not valid @@@
    end
    '''

    path = write_ext("brokenext", source)

    assert {:error, _reason} = Extensions.load_file(path)
    assert Extensions.fetch("broken_tool") == nil
  end

  defp write_ext(name, source) do
    path = Path.join(Extensions.dir(), name <> ".ex")
    File.write!(path, source)
    path
  end

  defp owner_hooks(owner) do
    Hooks.handlers(:before_tool_call) |> Enum.filter(&(&1.owner == owner))
  end

  defp shout_run_source do
    ~S'''
    defmodule Catalyst.Ext.ShoutRun do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: "shout_run"
      @impl true
      def description, do: "Uppercases text."
      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]}
      @impl true
      def execute(%{"text" => t}, _ctx), do: result(String.upcase(t))
    end
    '''
  end
end
