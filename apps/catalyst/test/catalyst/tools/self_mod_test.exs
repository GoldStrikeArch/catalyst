defmodule Catalyst.Tools.SelfModTest do
  # async: false — touches the global Extensions/Hooks/LLM registries + the
  # (shared, tmp) extensions dir.
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]
  import ExUnit.CaptureLog

  alias Catalyst.{Extensions, Hooks}
  alias Catalyst.Extensions.{Installer, Versioning}
  alias Catalyst.LLM.Registry
  alias Catalyst.Tools.{InstallExtension, ReloadTool, RollbackTool}

  setup do
    File.mkdir_p!(Extensions.dir())
    on_exit(fn -> File.rm_rf!(Extensions.dir()) end)
    {:ok, ctx: %{cwd: System.tmp_dir!(), call_id: "t", report: fn _ -> :ok end}}
  end

  @provider_ext ~S'''
  defmodule Catalyst.Ext.MyProvider do
    @behaviour Catalyst.LLM.Provider
    @impl true
    def stream(model, _ctx, _opts, _sink) do
      {:ok, %Catalyst.Message.Assistant{content: Catalyst.Content.text("hi"), model: model && model.id, stop_reason: :stop, timestamp: Catalyst.Message.now()}}
    end
  end

  defmodule Catalyst.Ext.ProviderInstaller do
    use Catalyst.Extension
    @impl true
    def setup(api) do
      Catalyst.ExtensionAPI.register_provider(api, "ext-echo",
        %Catalyst.LLM.ProviderConfig{module: Catalyst.Ext.MyProvider, name: "Ext Echo"})
      Catalyst.ExtensionAPI.register_hook(api, :before_tool_call, &Catalyst.Ext.ProviderInstaller.gate/1)
      :ok
    end
    def gate(_ctx), do: :cont
  end
  '''

  @tool_ext ~S'''
  defmodule Catalyst.Ext.ReloadedOne do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "reloaded_one"
    @impl true
    def description, do: "reloaded tool"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx), do: result("ok")
  end
  '''

  test "the self-modification tools are built in" do
    assert {:ok, _} = Extensions.fetch("install_extension")
    assert {:ok, _} = Extensions.fetch("reload_extensions")
    assert {:ok, _} = Extensions.fetch("rollback_extension")
  end

  test "install_extension registers a provider and a hook via setup (no tool needed)", %{ctx: ctx} do
    on_exit(fn -> Extensions.uninstall("provinstall") end)

    capture_log(fn ->
      assert %{content: _} =
               InstallExtension.execute(
                 %{"name" => "provinstall", "source" => @provider_ext},
                 ctx
               )
    end)

    assert {:ok, Catalyst.Ext.MyProvider} = Registry.fetch("ext-echo")
    assert Enum.any?(Hooks.handlers(:before_tool_call), &(&1.owner == "provinstall"))
  end

  test "a tuple-shaped install error is formatted, not Protocol.UndefinedError", %{ctx: ctx} do
    # `throw` during compilation produces an {:error, {kind, reason}} tuple;
    # the tool must inspect it rather than interpolate it.
    capture_log(fn ->
      err =
        assert_raise RuntimeError, fn ->
          InstallExtension.execute(%{"name" => "tuplereason", "source" => "throw(:nope)"}, ctx)
        end

      assert err.message =~ "{:throw, :nope}"
    end)
  end

  test "a tuple-shaped develop_tool error is formatted, not Protocol.UndefinedError", %{ctx: ctx} do
    capture_log(fn ->
      err =
        assert_raise RuntimeError, fn ->
          Catalyst.Tools.DevelopTool.execute(
            %{"name" => "tuplereason2", "source" => "throw(:nope)"},
            ctx
          )
        end

      assert err.message =~ "{:throw, :nope}"
    end)
  end

  @reinstall_v1 ~S'''
  defmodule Catalyst.Ext.ReinstallProbe do
    def version, do: :v1
  end
  '''

  @reinstall_v2_broken ~S'''
  defmodule Catalyst.Ext.ReinstallProbe do
    def version, do: :v2
  end

  defmodule Catalyst.Ext.ReinstallBoom do
    raise "boom at compile time"
  end
  '''

  @reinstall_v2 ~S'''
  defmodule Catalyst.Ext.ReinstallProbe do
    def version, do: :v2
  end
  '''

  test "a failed reinstall restores the prior version's loaded code, not just its file" do
    on_exit(fn -> Extensions.uninstall("reinstall_probe") end)

    capture_log(fn ->
      assert {:ok, _} = Installer.install("reinstall_probe", @reinstall_v1)
      assert apply(Catalyst.Ext.ReinstallProbe, :version, []) == :v1

      # v2's first module compiles (redefining the probe to :v2) before its
      # second module raises: restoring the backup bytes on disk alone would
      # leave the half-compiled v2 live in the VM with v1 in the file.
      assert {:error, _} = Installer.install("reinstall_probe", @reinstall_v2_broken)
      assert apply(Catalyst.Ext.ReinstallProbe, :version, []) == :v1

      # The file on disk is the restored v1 source, matching the loaded code.
      assert File.read!(Path.join(Extensions.dir(), "reinstall_probe.ex")) =~ ":v1"
    end)
  end

  test "an atomic install write failure preserves the prior source byte-for-byte" do
    case :os.type() do
      {:win32, _variant} ->
        :ok

      _unix ->
        on_exit(fn -> Extensions.uninstall("reinstall_probe") end)

        capture_log(fn ->
          assert {:ok, _summary} = Installer.install("reinstall_probe", @reinstall_v1)
        end)

        dir = Extensions.dir()
        path = Path.join(dir, "reinstall_probe.ex")
        original = File.read!(path)
        stat = File.stat!(dir)
        mode = band(stat.mode, 0o7777)

        try do
          # AtomicWrite creates its temp beside the target. Removing directory
          # write permission makes that creation fail before the existing
          # source can be truncated or replaced.
          File.chmod!(dir, 0o500)

          assert_raise File.Error, fn ->
            Installer.install("reinstall_probe", @reinstall_v2)
          end
        after
          File.chmod!(dir, mode)
        end

        assert File.read!(path) == original
        assert apply(Catalyst.Ext.ReinstallProbe, :version, []) == :v1
        assert Path.wildcard(Path.join(dir, ".reinstall_probe.ex.catalyst-*.tmp")) == []
    end
  end

  test "a broken install errors and leaves no file behind", %{ctx: ctx} do
    capture_log(fn ->
      assert_raise RuntimeError, fn ->
        InstallExtension.execute(
          %{"name" => "brokeninstall", "source" => "defmodule X do def @@@ end"},
          ctx
        )
      end
    end)

    refute File.exists?(Path.join(Extensions.dir(), "brokeninstall.ex"))
  end

  test "reload_extensions loads files written to the dir", %{ctx: ctx} do
    on_exit(fn -> Extensions.uninstall("reloaded_one_file") end)
    File.write!(Path.join(Extensions.dir(), "reloaded_one_file.ex"), @tool_ext)

    capture_log(fn -> assert %{content: _} = ReloadTool.execute(%{}, ctx) end)

    assert Extensions.fetch("reloaded_one") == {:ok, Catalyst.Ext.ReloadedOne}
  end

  test "reload_extensions lists files that fail to compile in its result", %{ctx: ctx} do
    on_exit(fn -> Extensions.uninstall("reloaded_one_file") end)
    File.write!(Path.join(Extensions.dir(), "reloaded_one_file.ex"), @tool_ext)
    File.write!(Path.join(Extensions.dir(), "broken_reload.ex"), "defmodule B do @@@ end")

    capture_log(fn ->
      %{content: content} = ReloadTool.execute(%{}, ctx)
      text = Catalyst.Content.text_of(content)
      assert text =~ "Reloaded 1 file(s)"
      assert text =~ "FAILED"
      assert text =~ "broken_reload.ex"
    end)
  end

  test "reload_extensions raises when nothing loads and something failed", %{ctx: ctx} do
    File.write!(Path.join(Extensions.dir(), "only_broken.ex"), "defmodule B do @@@ end")

    capture_log(fn ->
      assert_raise RuntimeError, ~r/Reload failed/, fn -> ReloadTool.execute(%{}, ctx) end
    end)
  end

  @gittool_ext ~S'''
  defmodule Catalyst.Ext.GitTool do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "git_tool"
    @impl true
    def description, do: "versioned tool"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx), do: result("ok")
  end
  '''

  @tag :git
  test "develop_tool changes are git-committed so rollback can revert them", %{ctx: ctx} do
    if Versioning.available?() do
      on_exit(fn -> Extensions.uninstall("gittool") end)
      Versioning.ensure_repo(Extensions.dir())

      capture_log(fn ->
        assert %{content: _} =
                 Catalyst.Tools.DevelopTool.execute(
                   %{"name" => "gittool", "source" => @gittool_ext},
                   ctx
                 )
      end)

      {log, 0} = System.cmd("git", ["log", "--oneline"], cd: Extensions.dir())
      assert log =~ "develop_tool gittool"
    end
  end

  @tag :git
  test "git versioning round-trips: commit then rollback removes the change" do
    if Versioning.available?() do
      dir = Path.join(System.tmp_dir!(), "catalyst_ver_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert :ok = Versioning.ensure_repo(dir)
      File.write!(Path.join(dir, "a.ex"), "content")
      assert :ok = Versioning.commit(dir, "add a")
      assert File.exists?(Path.join(dir, "a.ex"))

      assert :ok = Versioning.rollback(dir)
      refute File.exists?(Path.join(dir, "a.ex"))
    end
  end

  @tag :git
  test "committing byte-identical content is a no-op, not an empty commit" do
    if Versioning.available?() do
      dir = Path.join(System.tmp_dir!(), "catalyst_ver_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert :ok = Versioning.ensure_repo(dir)
      File.write!(Path.join(dir, "a.ex"), "content")
      assert :ok = Versioning.commit(dir, "add a")

      # Re-installing identical source: a clean tree must not grow an empty
      # commit, or the next rollback would revert the wrong change.
      assert :ok = Versioning.commit(dir, "add a again")
      {log, 0} = System.cmd("git", ["log", "--oneline"], cd: dir)
      assert length(String.split(String.trim(log), "\n")) == 2

      assert :ok = Versioning.rollback(dir)
      refute File.exists?(Path.join(dir, "a.ex"))
    end
  end

  @tag :git
  test "a failed revert leaves no sequencer state behind (later rollbacks work)" do
    if Versioning.available?() do
      dir = Path.join(System.tmp_dir!(), "catalyst_ver_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert :ok = Versioning.ensure_repo(dir)

      # HEAD is the empty init commit — reverting it fails (nothing to revert)...
      assert {:error, _} = Versioning.rollback(dir)

      # ...but a later, valid rollback must still work.
      File.write!(Path.join(dir, "a.ex"), "content")
      assert :ok = Versioning.commit(dir, "add a")
      assert :ok = Versioning.rollback(dir)
      refute File.exists?(Path.join(dir, "a.ex"))
    end
  end

  @rb_probe ~S'''
  defmodule Catalyst.Ext.RbProbe do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "rb_probe"
    @impl true
    def description, do: "rollback probe tool"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx), do: result("ok")
  end
  '''

  @tag :git
  test "the rollback_extension tool reverts the newest install end-to-end", %{ctx: ctx} do
    if Versioning.available?() do
      capture_log(fn ->
        {:ok, _summary} = Installer.install("rb_probe", @rb_probe, "install")
        assert {:ok, _mod} = Extensions.fetch("rb_probe")

        res = RollbackTool.execute(%{}, ctx)
        assert res.content |> hd() |> Map.get(:text) =~ "Rolled back"

        # The tool is gone from the live registry AND its source is reverted.
        assert Extensions.fetch("rb_probe") == :error
        refute File.exists?(Path.join(Extensions.dir(), "rb_probe.ex"))
      end)
    end
  end

  @tag :git
  test "the rollback_extension tool raises cleanly when there is nothing to revert", %{ctx: ctx} do
    if Versioning.available?() do
      Versioning.ensure_repo(Extensions.dir())

      assert_raise RuntimeError, ~r/Rollback failed/, fn ->
        RollbackTool.execute(%{}, ctx)
      end
    end
  end
end
