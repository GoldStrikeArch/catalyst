defmodule Catalyst.ExtensionsLoadTest do
  # async: false — Extensions is global, shared, mutable state.
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [put_env: 2]
  import Catalyst.ExtensionsFixtures
  import ExUnit.CaptureLog

  alias Catalyst.{Content, Message, Model}
  alias Catalyst.Agent.Loop
  alias Catalyst.Extensions
  alias Catalyst.ExtensionsFixtures.SetupOnlyTool
  alias Catalyst.Tools.DevelopTool

  setup do
    setup_extensions_dir()
  end

  test "the built-ins (incl. develop_tool) are seeded" do
    assert {:ok, _} = Extensions.fetch("read")
    assert Extensions.fetch("develop_tool") == {:ok, DevelopTool}
    assert "ast_grep" in Extensions.names()
  end

  test "an extension's optional metadata/0 is surfaced by list_loaded/0" do
    path = write_ext("meta_probe", meta_ext_source())
    on_exit(fn -> Extensions.uninstall("meta_probe") end)

    assert {:ok, _summary} = Extensions.load_file(path)

    info = Enum.find(Extensions.list_loaded(), &(&1.owner == "meta_probe"))
    assert info.metadata[:name] == "Meta Probe"
    assert info.metadata[:description] =~ "metadata/0"
  end

  test "the load lock mutually excludes different processes" do
    parent = self()

    holder =
      Task.async(fn ->
        Extensions.locked(fn ->
          send(parent, {:holder_in, self()})

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive {:holder_in, holder_transaction}, 1_000

    waiter = Task.async(fn -> Extensions.locked(fn -> send(parent, :waiter_in) end) end)

    # With the old fixed-atom lock requester, :global treated both processes
    # as "the same requester" and the waiter would enter immediately.
    refute_receive :waiter_in, 200

    send(holder_transaction, :release)
    # Generous deadline: :global.trans retries with randomized backoff, so a
    # contended waiter can legitimately take well over a second to re-acquire.
    assert_receive :waiter_in, 5_000
    Task.await_many([holder, waiter])
  end

  test "develop_tool compiles and loads a new tool at runtime (no restart)" do
    ctx = %{cwd: System.tmp_dir!(), call_id: "t", report: fn _ -> :ok end}

    capture_log(fn ->
      DevelopTool.execute(%{"name" => "shout_test", "source" => shout_source()}, ctx)
    end)

    # The freshly written module is now a live, registered tool.
    assert {:ok, mod} = Extensions.fetch("shout_test")
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

  test "an extension's setup/1 registers both a tool and a loop hook" do
    on_exit(fn -> Extensions.uninstall("multikind") end)
    path = write_ext("multikind", multikind_source())

    assert {:ok, summary} = Extensions.load_file(path)
    assert "mk_tool" in summary.tools

    assert Extensions.fetch("mk_tool") == {:ok, Catalyst.Ext.MultiKindTool}
    assert length(owner_hooks("multikind")) == 1
  end

  test "auto-loaded tools must return binary names" do
    source = ~S'''
    defmodule Catalyst.Ext.BadNameTool do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: :bad_name_tool
      @impl true
      def description, do: "bad tool"
      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
      @impl true
      def execute(_args, _ctx), do: result("bad")
    end
    '''

    path = write_ext("bad_name_tool", source)

    assert {:error, {:bad_tool_name, :bad_name_tool}} = Extensions.load_file(path)
    assert Extensions.fetch("bad_name_tool") == :error
    refute Code.ensure_loaded?(Catalyst.Ext.BadNameTool)
  end

  test "reloading an extension purges its prior hooks (no duplicates)" do
    on_exit(fn -> Extensions.uninstall("multikind") end)
    path = write_ext("multikind", multikind_source())

    Extensions.load_file(path)
    Extensions.load_file(path)

    assert length(owner_hooks("multikind")) == 1
  end

  test "setup/1 can register a tool through the API without deadlocking the server" do
    on_exit(fn -> Extensions.uninstall("setupreg") end)
    path = write_ext("setupreg", setup_reg_source())

    assert {:ok, summary} = Extensions.load_file(path)
    assert summary.extensions == [Catalyst.Ext.SetupReg]
    assert Extensions.fetch("setup_only_tool") == {:ok, SetupOnlyTool}

    # The setup-registered tool is owner-tracked, so uninstall removes it.
    Extensions.uninstall("setupreg")
    assert Extensions.fetch("setup_only_tool") == :error
  end

  test "a hanging extension compile is timed out without blocking the registry GenServer" do
    put_env(:extension_compile_timeout, 200)
    put_parent!(:compile_parent)
    compiler_options = Code.compiler_options()

    on_exit(fn -> Extensions.uninstall("compile_probe") end)

    path = write_ext("compile_hang", compile_hang_source())
    task = Task.async(fn -> Extensions.load_file(path) end)

    assert_receive :compile_started, 1_000
    assert {:ok, _} = Extensions.register_tool(SetupOnlyTool, owner: "compile_probe")
    assert {:error, :timeout} = Task.await(task, 1_000)
    assert Code.compiler_options() == compiler_options
  end

  test "a hanging extension setup is timed out without blocking the registry GenServer" do
    put_env(:extension_setup_timeout, 200)
    put_parent!(:setup_parent)

    on_exit(fn ->
      Extensions.uninstall("hanging_setup")
      Extensions.uninstall("setup_probe")
    end)

    log =
      capture_log(fn ->
        path = write_ext("hanging_setup", setup_hang_source())
        task = Task.async(fn -> Extensions.load_file(path) end)

        assert_receive :setup_started, 1_000
        assert {:ok, _} = Extensions.register_tool(SetupOnlyTool, owner: "setup_probe")
        assert {:ok, summary} = Task.await(task, 1_000)
        assert summary.warning =~ "setup did not finish cleanly"
      end)

    assert log =~ "setup timed out"
  end

  test "load_all reports per-file failures alongside the loaded summaries" do
    on_exit(fn -> Extensions.uninstall("goodfile") end)
    write_ext("goodfile", ephemeral_source())
    broken_path = write_ext("badfile", "defmodule Catalyst.Ext.BadFile do @@@ end")

    capture_log(fn ->
      assert {:ok, %{loaded: loaded, failed: [{^broken_path, reason}]}} = Extensions.load_all()
      assert Enum.any?(loaded, &(&1.owner == "goodfile"))
      assert Extensions.format_error(reason) =~ "badfile.ex"
    end)
  end

  test "redefining another owner's module is warned about and surfaced in the summary" do
    on_exit(fn ->
      Extensions.uninstall("conflict_a")
      Extensions.uninstall("conflict_b")
    end)

    path_a = write_ext("conflict_a", conflict_source(:a))
    path_b = write_ext("conflict_b", conflict_source(:b))

    capture_log(fn ->
      assert {:ok, summary_a} = Extensions.load_file(path_a)
      refute Map.has_key?(summary_a, :conflicts)
    end)

    log =
      capture_log(fn ->
        assert {:ok, summary_b} = Extensions.load_file(path_b)
        assert summary_b.conflicts == [{"conflict_a", [Catalyst.Ext.SharedMod]}]
      end)

    assert log =~ "also defined by extension"
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
    assert Extensions.fetch("broken_tool") == :error
  end

  test "list_loaded reports each owner's tools, modules, and source file" do
    on_exit(fn -> Extensions.uninstall("toggle") end)
    path = write_ext("toggle", toggle_source())
    assert {:ok, _summary} = Extensions.load_file(path)

    assert [entry] = Enum.filter(Extensions.list_loaded(), &(&1.owner == "toggle"))
    assert entry.path == path
    assert entry.tools == ["toggle_tool"]
    assert Catalyst.Ext.ToggleTool in entry.modules
  end

  test "setup return errors and exceptions are surfaced in load warnings" do
    returned =
      write_ext(
        "setup_returned_error",
        ~S'''
        defmodule Catalyst.Ext.SetupReturnedError do
          use Catalyst.Extension
          @impl true
          def setup(_api), do: {:error, :not_ready}
        end
        '''
      )

    raised =
      write_ext(
        "setup_raised_error",
        ~S'''
        defmodule Catalyst.Ext.SetupRaisedError do
          use Catalyst.Extension
          @impl true
          def setup(_api), do: raise("setup exploded")
        end
        '''
      )

    log =
      capture_log(fn ->
        assert {:ok, returned_summary} = Extensions.load_file(returned)
        assert returned_summary.warning =~ "not_ready"

        assert {:ok, raised_summary} = Extensions.load_file(raised)
        assert raised_summary.warning =~ "setup exploded"
      end)

    assert log =~ "returned {:error"
    assert log =~ "setup/1 raised: setup exploded"
  end

  test "tool registration metadata is bounded outside the Extensions server" do
    put_env(:tool_metadata_timeout, 100)
    put_parent!(:tool_metadata_parent)

    path =
      write_ext(
        "hanging_tool_metadata",
        ~S'''
        defmodule Catalyst.Ext.HangingToolMetadata do
          use Catalyst.Tools.Tool
          @impl true
          def name, do: "hanging_tool_metadata"
          @impl true
          def description do
            send(:persistent_term.get({Catalyst.ExtensionsFixtures, :tool_metadata_parent}), :tool_metadata_started)

            receive do
              :never -> "unreachable"
            end
          end
          @impl true
          def parameters, do: %{"type" => "object"}
          @impl true
          def execute(_args, _ctx), do: result("ok")
        end
        '''
      )

    task = Task.async(fn -> Extensions.load_file(path) end)
    assert_receive :tool_metadata_started

    assert {:ok, Catalyst.Tools.Read} = Extensions.fetch("read")

    assert {:error, {:tool_metadata_timeout, Catalyst.Ext.HangingToolMetadata}} =
             Task.await(task, 1_000)
  end

  test "extension metadata is bounded and cached after a successful load" do
    put_env(:extension_metadata_timeout, 50)
    put_parent!(:metadata_parent)

    cached =
      write_ext(
        "cached_metadata",
        ~S'''
        defmodule Catalyst.Ext.CachedMetadata do
          use Catalyst.Extension
          @impl true
          def metadata do
            send(:persistent_term.get({Catalyst.ExtensionsFixtures, :metadata_parent}), :metadata_called)
            %{name: "cached"}
          end
          @impl true
          def setup(_api), do: :ok
        end
        '''
      )

    assert {:ok, _} = Extensions.load_file(cached)
    assert_receive :metadata_called

    assert Enum.find(Extensions.list_loaded(), &(&1.owner == "cached_metadata")).metadata == %{
             name: "cached"
           }

    _ = Extensions.list_loaded()
    refute_receive :metadata_called

    hanging =
      write_ext(
        "hanging_metadata",
        ~S'''
        defmodule Catalyst.Ext.HangingMetadata do
          use Catalyst.Extension
          @impl true
          def metadata do
            receive do
              :never -> %{}
            end
          end
          @impl true
          def setup(_api), do: :ok
        end
        '''
      )

    assert {:ok, _} = Extensions.load_file(hanging)
    assert Enum.find(Extensions.list_loaded(), &(&1.owner == "hanging_metadata")).metadata == %{}
  end
end
