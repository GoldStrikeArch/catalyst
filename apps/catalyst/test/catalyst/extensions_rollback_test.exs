defmodule Catalyst.ExtensionsRollbackTest do
  # async: false — Extensions is global, shared, mutable state.
  use ExUnit.Case, async: false

  import Catalyst.ExtensionsFixtures
  import ExUnit.CaptureLog

  alias Catalyst.Extensions

  setup do
    setup_extensions_dir()
  end

  test "load_all purges contributions whose source file was removed (rollback path)" do
    path = write_ext("ephemeral", ephemeral_source())

    assert {:ok, _} = Extensions.load_file(path)
    assert {:ok, _} = Extensions.fetch("ephemeral_tool")

    # A rollback (or manual delete) removes the file; reload must deactivate it.
    File.rm!(path)
    capture_log(fn -> Extensions.load_all() end)
    assert Extensions.fetch("ephemeral_tool") == :error
  end

  test "load_all keeps owners registered without a backing file (register_tool owner:)" do
    on_exit(fn -> Extensions.uninstall("no_file_owner") end)

    assert {:ok, _} =
             Extensions.register_tool(Catalyst.ExtensionsFixtures.SetupOnlyTool,
               owner: "no_file_owner"
             )

    # The gone-file purge applies to file-backed owners only: this owner has no
    # *.ex file, but its registration must survive a directory reload.
    capture_log(fn -> Extensions.load_all() end)

    assert Extensions.fetch("setup_only_tool") ==
             {:ok, Catalyst.ExtensionsFixtures.SetupOnlyTool}
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
    path = write_ext("multikind", multikind_source())

    capture_log(fn ->
      Extensions.load_file(path)
      Extensions.load_file(path)
    end)

    assert Extensions.fetch("mk_tool") == {:ok, Catalyst.Ext.MultiKindTool}
    assert apply(Catalyst.Ext.MultiKindTool, :execute, [%{}, %{}]).content
  end

  test "a failed multi-module compile purges the modules it partially defined" do
    refute Code.ensure_loaded?(Catalyst.Ext.PartialFirst)

    path = write_ext("partial_new", partial_source())

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
end
