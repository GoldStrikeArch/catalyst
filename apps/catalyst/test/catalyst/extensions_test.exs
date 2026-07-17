defmodule Catalyst.ExtensionsTest do
  # async: false — Extensions is global, shared, mutable state.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Catalyst.{Content, Hooks, Message, Model}
  alias Catalyst.Agent.Loop
  alias Catalyst.Extensions
  alias Catalyst.Tools.{DevelopTool, ReloadTool}

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
    assert {:ok, _} = Extensions.fetch("read")
    assert Extensions.fetch("develop_tool") == {:ok, DevelopTool}
    assert "ast_grep" in Extensions.names()
  end

  @meta_ext_source ~S'''
  defmodule Catalyst.Ext.MetaProbe do
    use Catalyst.Extension

    @impl true
    def metadata, do: %{name: "Meta Probe", description: "self-description via metadata/0"}

    @impl true
    def setup(_api), do: :ok
  end
  '''

  test "an extension's optional metadata/0 is surfaced by list_loaded/0" do
    path = Path.join(Extensions.dir(), "meta_probe.ex")
    File.write!(path, @meta_ext_source)
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
    assert_receive :waiter_in, 1_000
    Task.await_many([holder, waiter])
  end

  test "develop_tool compiles and loads a new tool at runtime (no restart)" do
    ctx = %{cwd: System.tmp_dir!(), call_id: "t", report: fn _ -> :ok end}

    capture_log(fn ->
      DevelopTool.execute(%{"name" => "shout_test", "source" => @shout_source}, ctx)
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
    assert Extensions.fetch("setup_only_tool") == {:ok, SetupOnlyTool}

    # The setup-registered tool is owner-tracked, so uninstall removes it.
    Extensions.uninstall("setupreg")
    assert Extensions.fetch("setup_only_tool") == :error
  end

  @compile_hang_source ~S'''
  send(:persistent_term.get({Catalyst.ExtensionsTest, :compile_parent}), :compile_started)

  receive do
    :never -> :ok
  end

  defmodule Catalyst.Ext.CompileHang do
    def marker, do: :never
  end
  '''

  test "a hanging extension compile is timed out without blocking the registry GenServer" do
    put_app_env(:extension_compile_timeout, 200)
    :persistent_term.put({__MODULE__, :compile_parent}, self())
    compiler_options = Code.compiler_options()

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :compile_parent})
      Extensions.uninstall("compile_probe")
    end)

    path = write_ext("compile_hang", @compile_hang_source)
    task = Task.async(fn -> Extensions.load_file(path) end)

    assert_receive :compile_started, 1_000
    assert {:ok, _} = Extensions.register_tool(SetupOnlyTool, owner: "compile_probe")
    assert {:error, :timeout} = Task.await(task, 1_000)
    assert Code.compiler_options() == compiler_options
  end

  @setup_hang_source ~S'''
  defmodule Catalyst.Ext.HangingSetup do
    use Catalyst.Extension
    @impl true
    def setup(_api) do
      send(:persistent_term.get({Catalyst.ExtensionsTest, :setup_parent}), :setup_started)

      receive do
        :never -> :ok
      end
    end
  end
  '''

  test "a hanging extension setup is timed out without blocking the registry GenServer" do
    put_app_env(:extension_setup_timeout, 200)
    :persistent_term.put({__MODULE__, :setup_parent}, self())

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :setup_parent})
      Extensions.uninstall("hanging_setup")
      Extensions.uninstall("setup_probe")
    end)

    log =
      capture_log(fn ->
        path = write_ext("hanging_setup", @setup_hang_source)
        task = Task.async(fn -> Extensions.load_file(path) end)

        assert_receive :setup_started, 1_000
        assert {:ok, _} = Extensions.register_tool(SetupOnlyTool, owner: "setup_probe")
        assert {:ok, summary} = Task.await(task, 1_000)
        assert summary.warning =~ "setup did not finish cleanly"
      end)

    assert log =~ "setup timed out"
  end

  test "killing a load caller cannot abandon a committed setup collision" do
    put_app_env(:extension_setup_timeout, 100)
    key = {__MODULE__, :cancelled_setup_parent}
    :persistent_term.put(key, self())

    on_exit(fn ->
      :persistent_term.erase(key)
      Extensions.uninstall("cancelled_provider_owner_b")
      Extensions.uninstall("cancelled_provider_owner_a")
    end)

    first =
      write_ext(
        "cancelled_provider_owner_a",
        ~S'''
        defmodule Catalyst.Ext.CancelledOwnedProvider do
          def identity, do: :a
        end

        defmodule Catalyst.Ext.CancelledProviderAExtension do
          use Catalyst.Extension

          @impl true
          def setup(api) do
            Catalyst.ExtensionAPI.register_provider(
              api,
              "cancelled-owned-provider",
              Catalyst.Ext.CancelledOwnedProvider
            )
          end
        end
        '''
      )

    second =
      write_ext(
        "cancelled_provider_owner_b",
        ~S'''
        defmodule Catalyst.Ext.CancelledOwnedProvider do
          def identity, do: :b
        end

        defmodule Catalyst.Ext.CancelledProviderBExtension do
          use Catalyst.Extension

          @impl true
          def setup(api) do
            _ignored =
              Catalyst.ExtensionAPI.register_provider(
                api,
                "cancelled-owned-provider",
                Catalyst.Ext.CancelledOwnedProvider
              )

            send(
              :persistent_term.get({Catalyst.ExtensionsTest, :cancelled_setup_parent}),
              {:cancelled_setup_started, self()}
            )

            receive do
              :never -> :ok
            end
          end
        end
        '''
      )

    assert {:ok, _} = Extensions.load_file(first)
    caller = start_supervised!({Task, fn -> Extensions.load_file(second) end})
    assert_receive {:cancelled_setup_started, setup_task}
    setup_ref = Process.monitor(setup_task)

    ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
    assert_receive {:DOWN, ^setup_ref, :process, ^setup_task, :killed}, 1_000

    # A second serialized transaction waits for the abandoned caller's durable
    # transaction to finish its timeout, collision rejection, and restoration.
    assert :ok = Extensions.locked(fn -> :ok end)

    state = :sys.get_state(Extensions)
    assert state.setup_collisions == %{}
    refute Enum.any?(Extensions.list_loaded(), &(&1.owner == "cancelled_provider_owner_b"))
    assert apply(Catalyst.Ext.CancelledOwnedProvider, :identity, []) == :a
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
    assert {:ok, _} = Extensions.fetch("ephemeral_tool")

    # A rollback (or manual delete) removes the file; reload must deactivate it.
    File.rm!(path)
    capture_log(fn -> Extensions.load_all() end)
    assert Extensions.fetch("ephemeral_tool") == :error
  end

  test "load_all keeps owners registered without a backing file (register_tool owner:)" do
    on_exit(fn -> Extensions.uninstall("no_file_owner") end)
    assert {:ok, _} = Extensions.register_tool(SetupOnlyTool, owner: "no_file_owner")

    # The gone-file purge applies to file-backed owners only: this owner has no
    # *.ex file, but its registration must survive a directory reload.
    capture_log(fn -> Extensions.load_all() end)

    assert Extensions.fetch("setup_only_tool") == {:ok, SetupOnlyTool}
  end

  test "load_all reports per-file failures alongside the loaded summaries" do
    on_exit(fn -> Extensions.uninstall("goodfile") end)
    write_ext("goodfile", @ephemeral_source)
    broken_path = write_ext("badfile", "defmodule Catalyst.Ext.BadFile do @@@ end")

    capture_log(fn ->
      assert {:ok, %{loaded: loaded, failed: [{^broken_path, reason}]}} = Extensions.load_all()
      assert Enum.any?(loaded, &(&1.owner == "goodfile"))
      assert Extensions.format_error(reason) =~ "badfile.ex"
    end)
  end

  @conflict_a ~S'''
  defmodule Catalyst.Ext.SharedMod do
    def origin, do: :a
  end
  '''

  @conflict_b ~S'''
  defmodule Catalyst.Ext.SharedMod do
    def origin, do: :b
  end
  '''

  test "redefining another owner's module is warned about and surfaced in the summary" do
    on_exit(fn ->
      Extensions.uninstall("conflict_a")
      Extensions.uninstall("conflict_b")
    end)

    path_a = write_ext("conflict_a", @conflict_a)
    path_b = write_ext("conflict_b", @conflict_b)

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
    assert Extensions.fetch("vanishing_tool") == :error
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

    assert apply(Catalyst.Ext.Shadowed, :version, []) == :original

    # An extension redefines (shadows) it...
    path =
      write_ext("shadower", ~S'''
      defmodule Catalyst.Ext.Shadowed do
        def version, do: :shadowed
      end
      ''')

    capture_log(fn -> assert {:ok, _} = Extensions.load_file(path) end)
    assert apply(Catalyst.Ext.Shadowed, :version, []) == :shadowed

    # ...and removing the extension restores the original code, not just the registry.
    File.rm!(path)
    capture_log(fn -> Extensions.load_all() end)
    assert apply(Catalyst.Ext.Shadowed, :version, []) == :original
  end

  test "reloading the same file keeps its modules (no restore-clobber mid-reload)" do
    on_exit(fn -> Extensions.uninstall("multikind") end)
    path = write_ext("multikind", @multikind_source)

    capture_log(fn ->
      Extensions.load_file(path)
      Extensions.load_file(path)
    end)

    assert Extensions.fetch("mk_tool") == {:ok, Catalyst.Ext.MultiKindTool}
    assert apply(Catalyst.Ext.MultiKindTool, :execute, [%{}, %{}]).content
  end

  defp capture_log_compile(source) do
    # Code.compile_string warns when redefining across runs; keep logs quiet.
    import ExUnit.CaptureIO
    {result, _io} = with_io(:stderr, fn -> Code.compile_string(source) end)
    result
  end

  defp put_app_env(key, value) do
    previous = Application.fetch_env(:catalyst, key)
    Application.put_env(:catalyst, key, value)
    on_exit(fn -> restore_app_env(key, previous) end)
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:catalyst, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:catalyst, key)

  @partial_source ~S'''
  defmodule Catalyst.Ext.PartialFirst do
    def marker, do: :first
  end

  defmodule Catalyst.Ext.PartialBoom do
    raise "boom at compile time"
  end
  '''

  test "a failed multi-module compile purges the modules it partially defined" do
    refute Code.ensure_loaded?(Catalyst.Ext.PartialFirst)

    path = write_ext("partial_new", @partial_source)

    capture_log(fn ->
      assert {:error, reason} = Extensions.load_file(path)
      assert Extensions.format_error(reason) =~ "boom"
    end)

    # Code.compile_file/1 defined PartialFirst before PartialBoom raised — the
    # failed load must not leave half the file's code live in the VM.
    refute Code.ensure_loaded?(Catalyst.Ext.PartialFirst)
    assert Extensions.fetch("partial_first") == :error
  end

  test "a failed same-owner reload restores the exact last-known-good BEAM" do
    path =
      write_ext(
        "same_owner_partial",
        owned_tool_source(
          "Catalyst.Ext.SameOwnerPartialTool",
          "same_owner_partial_tool",
          "version one"
        )
      )

    on_exit(fn -> Extensions.uninstall("same_owner_partial") end)

    assert {:ok, _summary} = Extensions.load_file(path)
    assert apply(Catalyst.Ext.SameOwnerPartialTool, :description, []) == "version one"

    File.write!(
      path,
      owned_tool_source(
        "Catalyst.Ext.SameOwnerPartialTool",
        "same_owner_partial_tool",
        "version two"
      ) <> "\nraise \"same-owner reload failed after redefining the module\"\n"
    )

    capture_log(fn ->
      assert {:error, reason} = Extensions.reload("same_owner_partial")
      assert Extensions.format_error(reason) =~ "same-owner reload failed"
    end)

    assert {:ok, Catalyst.Ext.SameOwnerPartialTool} =
             Extensions.fetch("same_owner_partial_tool")

    assert Code.ensure_loaded?(Catalyst.Ext.SameOwnerPartialTool)
    assert apply(Catalyst.Ext.SameOwnerPartialTool, :description, []) == "version one"
  end

  test "a partial compile restores a same-named module owned by another file" do
    first =
      write_ext(
        "partial_overlap_a",
        ~S'''
        defmodule Catalyst.Ext.PartialOverlapShared do
          def marker, do: :a
        end
        '''
      )

    second =
      write_ext(
        "partial_overlap_b",
        ~S'''
        defmodule Catalyst.Ext.PartialOverlapShared do
          def marker, do: :b
        end

        defmodule Catalyst.Ext.PartialOverlapBoom do
          raise "partial overlap boom"
        end
        '''
      )

    on_exit(fn ->
      Extensions.uninstall("partial_overlap_b")
      Extensions.uninstall("partial_overlap_a")
    end)

    assert {:ok, _} = Extensions.load_file(first)
    assert apply(Catalyst.Ext.PartialOverlapShared, :marker, []) == :a

    capture_log(fn ->
      assert {:error, reason} = Extensions.load_file(second)
      assert Extensions.format_error(reason) =~ "partial overlap boom"
    end)

    assert apply(Catalyst.Ext.PartialOverlapShared, :marker, []) == :a
  end

  test "a partial compile restores a dynamically named module owned by another file" do
    first =
      write_ext(
        "dynamic_partial_overlap_a",
        ~S'''
        module = Module.concat(["Catalyst", "Ext", "DynamicPartialOverlapShared"])

        defmodule module do
          def marker, do: :a
        end
        '''
      )

    second =
      write_ext(
        "dynamic_partial_overlap_b",
        ~S'''
        module = Module.concat(["Catalyst", "Ext", "DynamicPartialOverlapShared"])

        defmodule module do
          def marker, do: :b
        end

        raise "dynamic partial overlap boom"
        '''
      )

    on_exit(fn ->
      Extensions.uninstall("dynamic_partial_overlap_b")
      Extensions.uninstall("dynamic_partial_overlap_a")
    end)

    assert {:ok, _} = Extensions.load_file(first)
    assert apply(Catalyst.Ext.DynamicPartialOverlapShared, :marker, []) == :a

    capture_log(fn ->
      assert {:error, reason} = Extensions.load_file(second)
      assert Extensions.format_error(reason) =~ "dynamic partial overlap boom"
    end)

    assert apply(Catalyst.Ext.DynamicPartialOverlapShared, :marker, []) == :a
  end

  test "partial compile cleanup leaves modules in non-executed branches untouched" do
    module = Catalyst.Ext.UnexecutedPartialCandidate

    Code.compile_string("""
    defmodule #{inspect(module)} do
      def marker, do: :untouched
    end
    """)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    path =
      write_ext(
        "unexecuted_partial_candidate",
        """
        if false do
          defmodule #{inspect(module)} do
            def marker, do: :must_not_load
          end
        end

        raise "failure after non-executed branch"
        """
      )

    capture_log(fn -> assert {:error, _reason} = Extensions.load_file(path) end)
    assert apply(module, :marker, []) == :untouched
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

  @toggle_source ~S'''
  defmodule Catalyst.Ext.ToggleTool do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "toggle_tool"
    @impl true
    def description, do: "disable/enable round-trip test tool"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx), do: result("ok")
  end
  '''

  test "list_loaded reports each owner's tools, modules, and source file" do
    on_exit(fn -> Extensions.uninstall("toggle") end)
    path = write_ext("toggle", @toggle_source)
    assert {:ok, _summary} = Extensions.load_file(path)

    assert [entry] = Enum.filter(Extensions.list_loaded(), &(&1.owner == "toggle"))
    assert entry.path == path
    assert entry.tools == ["toggle_tool"]
    assert Catalyst.Ext.ToggleTool in entry.modules
  end

  test "disable purges + renames the file; load_all keeps it off; enable restores it" do
    on_exit(fn -> Extensions.uninstall("toggle") end)
    path = write_ext("toggle", @toggle_source)
    assert {:ok, _summary} = Extensions.load_file(path)
    assert {:ok, _mod} = Extensions.fetch("toggle_tool")

    assert {:ok, disabled} = Extensions.disable("toggle")
    assert disabled == path <> ".disabled"
    assert File.exists?(disabled)
    refute File.exists?(path)
    assert Extensions.fetch("toggle_tool") == :error
    refute Enum.any?(Extensions.list_loaded(), &(&1.owner == "toggle"))
    assert [%{owner: "toggle"}] = Extensions.list_disabled()

    # A full reload (≈ next boot) must not resurrect a disabled extension.
    {:ok, _} = Extensions.load_all()
    assert Extensions.fetch("toggle_tool") == :error

    assert {:ok, summary} = Extensions.enable("toggle")
    assert summary.tools == ["toggle_tool"]
    assert {:ok, _mod} = Extensions.fetch("toggle_tool")
    assert Extensions.list_disabled() == []
  end

  test "disable/enable for an owner with no source file return :no_file" do
    assert {:error, :no_file} = Extensions.disable("no_such_owner")
    assert {:error, :no_file} = Extensions.enable("no_such_owner")
  end

  test "an externally loaded extension is reload-only and cannot be stranded by disable" do
    external_dir =
      Path.join(
        System.tmp_dir!(),
        "catalyst_external_disable_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(external_dir)
    path = Path.join(external_dir, "external_disable.ex")

    File.write!(
      path,
      owned_tool_source(
        "Catalyst.Ext.ExternalDisableTool",
        "external_disable_tool",
        "external"
      )
    )

    on_exit(fn ->
      Extensions.uninstall("external_disable")
      File.rm_rf!(external_dir)
    end)

    assert {:ok, _summary} = Extensions.load_file(path)
    info = Enum.find(Extensions.list_loaded(), &(&1.owner == "external_disable"))
    refute info.managed?

    assert {:error, :external_source} = Extensions.disable("external_disable")
    assert File.regular?(path)
    refute File.exists?(path <> ".disabled")
    assert {:ok, Catalyst.Ext.ExternalDisableTool} = Extensions.fetch("external_disable_tool")
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

  test "colliding normalized filenames reject the directory load before compiling" do
    first = Path.join(Extensions.dir(), "Owner One.ex")
    second = Path.join(Extensions.dir(), "owner---one.ex")
    File.write!(first, "defmodule Catalyst.Ext.OwnerOneA do end")
    File.write!(second, "defmodule Catalyst.Ext.OwnerOneB do end")

    assert {:error, {:owner_collision, "owner_one", paths}} = Extensions.load_all()
    assert Enum.sort(paths) == Enum.sort([first, second])
    refute Code.ensure_loaded?(Catalyst.Ext.OwnerOneA)
    refute Code.ensure_loaded?(Catalyst.Ext.OwnerOneB)
  end

  test "reload tool surfaces colliding normalized filenames without a match error" do
    File.write!(
      Path.join(Extensions.dir(), "Owner One.ex"),
      "defmodule Catalyst.Ext.OwnerOneA do end"
    )

    File.write!(
      Path.join(Extensions.dir(), "owner---one.ex"),
      "defmodule Catalyst.Ext.OwnerOneB do end"
    )

    assert_raise RuntimeError, ~r/multiple extension files normalize to owner "owner_one"/, fn ->
      ReloadTool.execute(%{}, %{})
    end
  end

  test "a second extension owner cannot replace an extension-owned tool" do
    first =
      write_ext(
        "tool_owner_a",
        owned_tool_source("Catalyst.Ext.OwnedToolA", "owned_collision", "owner a")
      )

    second =
      write_ext(
        "tool_owner_b",
        owned_tool_source("Catalyst.Ext.OwnedToolB", "owned_collision", "owner b")
      )

    assert {:ok, _} = Extensions.load_file(first)

    assert {:error, {:tool_owner_collision, "owned_collision", "tool_owner_a", "tool_owner_b"}} =
             Extensions.load_file(second)

    assert {:ok, Catalyst.Ext.OwnedToolA} = Extensions.fetch("owned_collision")

    :ok = Extensions.uninstall("tool_owner_b")
    assert {:ok, Catalyst.Ext.OwnedToolA} = Extensions.fetch("owned_collision")

    :ok = Extensions.uninstall("tool_owner_a")
    assert :error = Extensions.fetch("owned_collision")
  end

  test "an ownerless host registration cannot detach an extension-owned tool" do
    path = write_ext("setupreg", @setup_reg_source)
    on_exit(fn -> Extensions.uninstall("setupreg") end)

    assert {:ok, _summary} = Extensions.load_file(path)

    assert {:error, {:tool_owner_collision, "setup_only_tool", "setupreg", :host}} =
             Extensions.register_tool(SetupOnlyTool)

    assert {:ok, SetupOnlyTool} = Extensions.fetch("setup_only_tool")

    assert Enum.find(Extensions.list_loaded(), &(&1.owner == "setupreg")).tools == [
             "setup_only_tool"
           ]
  end

  test "a rejected tool owner cannot leave a same-named module redefined" do
    module = "Catalyst.Ext.SameOwnedTool"

    first =
      write_ext(
        "same_tool_owner_a",
        owned_tool_source(module, "same_owned_collision", "owner a")
      )

    second =
      write_ext(
        "same_tool_owner_b",
        owned_tool_source(module, "same_owned_collision", "owner b")
      )

    on_exit(fn ->
      Extensions.uninstall("same_tool_owner_b")
      Extensions.uninstall("same_tool_owner_a")
    end)

    assert {:ok, _} = Extensions.load_file(first)
    assert apply(Catalyst.Ext.SameOwnedTool, :description, []) == "owner a"

    assert {:error,
            {:tool_owner_collision, "same_owned_collision", "same_tool_owner_a",
             "same_tool_owner_b"}} = Extensions.load_file(second)

    assert {:ok, Catalyst.Ext.SameOwnedTool} = Extensions.fetch("same_owned_collision")
    assert apply(Catalyst.Ext.SameOwnedTool, :description, []) == "owner a"

    :ok = Extensions.uninstall("same_tool_owner_b")
    assert apply(Catalyst.Ext.SameOwnedTool, :description, []) == "owner a"
  end

  test "collision restoration uses the tracked path for an externally loaded file" do
    external_dir =
      Path.join(System.tmp_dir!(), "catalyst_external_ext_#{System.unique_integer([:positive])}")

    File.mkdir_p!(external_dir)
    on_exit(fn -> File.rm_rf!(external_dir) end)

    first = Path.join(external_dir, "external_tool_owner_a.ex")

    File.write!(
      first,
      owned_tool_source("Catalyst.Ext.ExternalOwnedTool", "external_collision", "owner a")
    )

    second =
      write_ext(
        "external_tool_owner_b",
        owned_tool_source("Catalyst.Ext.ExternalOwnedTool", "external_collision", "owner b")
      )

    on_exit(fn ->
      Extensions.uninstall("external_tool_owner_b")
      Extensions.uninstall("external_tool_owner_a")
    end)

    assert {:ok, _} = Extensions.load_file(first)

    assert Enum.find(Extensions.list_loaded(), &(&1.owner == "external_tool_owner_a")).path ==
             first

    assert {:error,
            {:tool_owner_collision, "external_collision", "external_tool_owner_a",
             "external_tool_owner_b"}} = Extensions.load_file(second)

    assert apply(Catalyst.Ext.ExternalOwnedTool, :description, []) == "owner a"
  end

  test "a rejected distinct tool does not recompile or evict the live owner" do
    first =
      write_ext(
        "distinct_tool_owner_a",
        owned_tool_source("Catalyst.Ext.DistinctOwnedToolA", "distinct_collision", "owner a")
      )

    second =
      write_ext(
        "distinct_tool_owner_b",
        rejected_dynamic_module_source() <>
          owned_tool_source(
            "Catalyst.Ext.DistinctOwnedToolB",
            "distinct_collision",
            "owner b"
          )
      )

    on_exit(fn ->
      Extensions.uninstall("distinct_tool_owner_b")
      Extensions.uninstall("distinct_tool_owner_a")
    end)

    assert {:ok, _} = Extensions.load_file(first)
    File.write!(first, "this source is intentionally invalid @@@")

    assert {:error,
            {:tool_owner_collision, "distinct_collision", "distinct_tool_owner_a",
             "distinct_tool_owner_b"}} = Extensions.load_file(second)

    assert {:ok, Catalyst.Ext.DistinctOwnedToolA} = Extensions.fetch("distinct_collision")
    assert apply(Catalyst.Ext.DistinctOwnedToolA, :description, []) == "owner a"
    refute Code.ensure_loaded?(Catalyst.Ext.DistinctOwnedToolB)
    refute Code.ensure_loaded?(Catalyst.Ext.RejectedDynamicHelper)
  end

  test "a rejected provider owner cannot leave a same-named module redefined" do
    first = write_ext("same_provider_owner_a", owned_provider_source(:a))
    second = write_ext("same_provider_owner_b", owned_provider_source(:b))

    on_exit(fn ->
      Extensions.uninstall("same_provider_owner_b")
      Extensions.uninstall("same_provider_owner_a")
    end)

    assert {:ok, _} = Extensions.load_file(first)
    assert apply(Catalyst.Ext.SameOwnedProvider, :identity, []) == :a

    assert {:error,
            {:provider_owner_collision, "same-owned-provider", "same_provider_owner_a",
             "same_provider_owner_b"}} = Extensions.load_file(second)

    assert Catalyst.LLM.Registry.fetch_config("same-owned-provider").module ==
             Catalyst.Ext.SameOwnedProvider

    assert apply(Catalyst.Ext.SameOwnedProvider, :identity, []) == :a

    :ok = Extensions.uninstall("same_provider_owner_b")
    assert apply(Catalyst.Ext.SameOwnedProvider, :identity, []) == :a
  end

  test "a timed-out setup cannot hide an ignored provider owner collision" do
    put_app_env(:extension_setup_timeout, 100)
    key = {__MODULE__, :timed_collision_parent}
    :persistent_term.put(key, self())

    first = write_ext("timed_provider_owner_a", timed_provider_source(:a, false))
    second = write_ext("timed_provider_owner_b", timed_provider_source(:b, true))

    on_exit(fn ->
      :persistent_term.erase(key)
      Extensions.uninstall("timed_provider_owner_b")
      Extensions.uninstall("timed_provider_owner_a")
    end)

    assert {:ok, _} = Extensions.load_file(first)

    assert {:error,
            {:provider_owner_collision, "timed-owned-provider", "timed_provider_owner_a",
             "timed_provider_owner_b"}} = Extensions.load_file(second)

    assert_receive :timed_collision_recorded
    assert apply(Catalyst.Ext.TimedOwnedProvider, :identity, []) == :a
  end

  test "an extension may shadow a built-in tool and purge restores it" do
    path =
      write_ext(
        "read_shadow",
        owned_tool_source("Catalyst.Ext.ReadShadow", "read", "extension read override")
      )

    assert {:ok, _summary} = Extensions.load_file(path)
    assert {:ok, Catalyst.Ext.ReadShadow} = Extensions.fetch("read")

    assert :ok = Extensions.uninstall("read_shadow")
    assert {:ok, Catalyst.Tools.Read} = Extensions.fetch("read")
  end

  test "tool registration metadata is bounded outside the Extensions server" do
    put_app_env(:tool_metadata_timeout, 100)
    key = {__MODULE__, :tool_metadata_parent}
    :persistent_term.put(key, self())
    on_exit(fn -> :persistent_term.erase(key) end)

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
            send(:persistent_term.get({Catalyst.ExtensionsTest, :tool_metadata_parent}), :tool_metadata_started)

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
    put_app_env(:extension_metadata_timeout, 50)
    key = {__MODULE__, :metadata_parent}
    :persistent_term.put(key, self())
    on_exit(fn -> :persistent_term.erase(key) end)

    cached =
      write_ext(
        "cached_metadata",
        ~S'''
        defmodule Catalyst.Ext.CachedMetadata do
          use Catalyst.Extension
          @impl true
          def metadata do
            send(:persistent_term.get({Catalyst.ExtensionsTest, :metadata_parent}), :metadata_called)
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

  defp write_ext(name, source) do
    path = Path.join(Extensions.dir(), name <> ".ex")
    File.write!(path, source)
    path
  end

  defp owner_hooks(owner) do
    Hooks.handlers(:before_tool_call) |> Enum.filter(&(&1.owner == owner))
  end

  defp owned_tool_source(module, name, description) do
    """
    defmodule #{module} do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: #{inspect(name)}
      @impl true
      def description, do: #{inspect(description)}
      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
      @impl true
      def execute(_args, _ctx), do: result("ok")
    end
    """
  end

  defp owned_provider_source(identity) do
    """
    defmodule Catalyst.Ext.SameOwnedProvider do
      def identity, do: #{inspect(identity)}
    end

    defmodule Catalyst.Ext.SameOwnedProviderExtension do
      use Catalyst.Extension

      @impl true
      def setup(api) do
        _ignored =
          Catalyst.ExtensionAPI.register_provider(
            api,
            "same-owned-provider",
            Catalyst.Ext.SameOwnedProvider
          )

        :ok
      end
    end
    """
  end

  defp rejected_dynamic_module_source do
    """
    dynamic_module = Module.concat(["Catalyst", "Ext", "RejectedDynamicHelper"])

    defmodule dynamic_module do
      def marker, do: :must_be_purged
    end

    """
  end

  defp timed_provider_source(identity, hang?) do
    after_registration =
      case hang? do
        true ->
          """
          send(
            :persistent_term.get({Catalyst.ExtensionsTest, :timed_collision_parent}),
            :timed_collision_recorded
          )

          receive do
            :never -> :ok
          end
          """

        false ->
          ":ok"
      end

    """
    defmodule Catalyst.Ext.TimedOwnedProvider do
      def identity, do: #{inspect(identity)}
    end

    defmodule Catalyst.Ext.TimedOwnedProviderExtension do
      use Catalyst.Extension

      @impl true
      def setup(api) do
        _ignored =
          Catalyst.ExtensionAPI.register_provider(
            api,
            "timed-owned-provider",
            Catalyst.Ext.TimedOwnedProvider
          )

        #{after_registration}
      end
    end
    """
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
