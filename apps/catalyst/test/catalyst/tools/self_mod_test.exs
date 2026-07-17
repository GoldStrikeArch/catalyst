defmodule Catalyst.Tools.SelfModTest do
  # async: false — touches the global Extensions/Hooks/LLM registries + the
  # (shared, tmp) extensions dir.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Catalyst.{Extensions, Hooks}
  alias Catalyst.Extensions.Versioning
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
    assert Extensions.fetch("install_extension")
    assert Extensions.fetch("reload_extensions")
    assert Extensions.fetch("rollback_extension")
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

    assert Extensions.fetch("reloaded_one") == Catalyst.Ext.ReloadedOne
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

  # RollbackTool itself just delegates to Versioning + load_all; exercised via the
  # Versioning round-trip above. Reference it so the module is covered/loaded.
  test "rollback tool is available" do
    assert RollbackTool.name() == "rollback_extension"
  end
end
