defmodule CatalystCliTest do
  # async: false — `selftest` writes to and loads from the global, shared
  # extensions dir (a tmp path in test) and registers into the process-wide
  # Catalyst.Extensions registry.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "`tools` lists the registered tools and returns :ok" do
    out = capture_io(fn -> assert CatalystCli.run(["tools"]) == :ok end)
    assert out =~ "registered tools:"
  end

  test "`selftest` compiles, loads, and runs a brand-new tool at runtime" do
    File.mkdir_p!(Catalyst.Extensions.dir())

    on_exit(fn ->
      Catalyst.Extensions.uninstall("cli_shout")
      File.rm_rf!(Catalyst.Extensions.dir())
    end)

    out = capture_io(fn -> assert CatalystCli.run(["selftest"]) == :ok end)

    assert out =~ "compiled + loaded at runtime"
    # The loaded tool upcases its input — seeing this proves NEW code ran in this VM.
    assert out =~ "PACKAGED HOT-LOAD WORKS"
    assert out =~ "loaded NEW code into the running VM"
  end

  test "an unknown command prints usage and returns :error (drives a non-zero exit)" do
    out = capture_io(fn -> assert CatalystCli.run(["bogus"]) == :error end)
    assert out =~ "usage: catalyst"
  end
end
