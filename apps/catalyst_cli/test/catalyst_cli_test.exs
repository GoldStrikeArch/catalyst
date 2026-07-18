defmodule CatalystCliTest do
  # async: false — `selftest` registers into the process-wide Extensions
  # registry, and the clean-halt test temporarily redirects the boot marker.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "`tools` lists the registered tools and returns :ok" do
    out = capture_io(fn -> assert CatalystCli.run(["tools"]) == :ok end)
    assert out =~ "registered tools:"
  end

  test "`selftest` compiles, loads, and runs a brand-new tool at runtime" do
    File.mkdir_p!(Catalyst.Extensions.dir())
    assert {:ok, %{failed: []}} = Catalyst.Extensions.load_all()

    user_path = Path.join(Catalyst.Extensions.dir(), "cli_shout.ex")
    user_source = "# user-owned extension sentinel\n"
    File.write!(user_path, user_source)
    loaded_before = Catalyst.Extensions.list_loaded()
    env_before = System.get_env("CATALYST_HOME")
    home_before = Application.fetch_env(:catalyst, :home)
    extensions_before = Application.fetch_env(:catalyst, :extensions_dir)
    marker_before = Application.fetch_env(:catalyst, :boot_marker_path)

    on_exit(fn ->
      File.rm(user_path)
      File.rm_rf!(Catalyst.Extensions.dir())
    end)

    out =
      capture_io(fn ->
        assert CatalystCli.run(["selftest"]) == :ok
        assert CatalystCli.run(["selftest"]) == :ok
      end)

    assert out =~ "compiled + loaded at runtime"
    # The loaded tool upcases its input — seeing this proves NEW code ran in this VM.
    assert out =~ "PACKAGED HOT-LOAD WORKS"
    assert out =~ "loaded NEW code into the running VM"
    assert length(Regex.scan(~r/loaded NEW code into the running VM/, out)) == 2

    # Regression: the historical fixed name is user-owned here. The selftest
    # uses isolated, unique identifiers and must neither overwrite nor delete it.
    assert out =~ "cleaned up"
    assert File.read!(user_path) == user_source
    assert Catalyst.Extensions.fetch("cli_shout") == :error
    assert Catalyst.Extensions.list_loaded() == loaded_before
    assert System.get_env("CATALYST_HOME") == env_before
    assert Application.fetch_env(:catalyst, :home) == home_before
    assert Application.fetch_env(:catalyst, :extensions_dir) == extensions_before
    assert Application.fetch_env(:catalyst, :boot_marker_path) == marker_before
  end

  test "controlled halt marks extension boot clean before invoking the halter" do
    marker =
      Path.join(System.tmp_dir!(), "catalyst_cli_marker_#{System.unique_integer([:positive])}")

    previous_marker = Application.get_env(:catalyst, :boot_marker_path)
    status_key = {Catalyst.Extensions, :boot_status}
    previous_status = :persistent_term.get(status_key, :missing)

    Application.put_env(:catalyst, :boot_marker_path, marker)
    :persistent_term.put(status_key, :ok)
    Catalyst.Extensions.BootGuard.mark_booting()

    on_exit(fn ->
      restore_env(:catalyst, :boot_marker_path, previous_marker)
      restore_persistent(status_key, previous_status)
      File.rm(marker)
    end)

    assert :halted =
             CatalystCli.Application.clean_halt(7, fn code ->
               assert File.read!(marker) == "ok\n"
               assert code == 7
               :halted
             end)
  end

  test "an unknown command prints usage and returns :error (drives a non-zero exit)" do
    out = capture_io(fn -> assert CatalystCli.run(["bogus"]) == :error end)
    assert out =~ "usage: catalyst"
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp restore_persistent(key, :missing), do: :persistent_term.erase(key)
  defp restore_persistent(key, value), do: :persistent_term.put(key, value)
end
