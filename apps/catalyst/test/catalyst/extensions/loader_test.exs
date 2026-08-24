defmodule Catalyst.Extensions.LoaderTest do
  use ExUnit.Case, async: true

  alias Catalyst.Extensions.Loader

  @executable_suffix if(:os.type() == {:win32, :nt}, do: ".exe", else: "")

  test "uses erlexec when a packaged ERTS omits the erl launcher" do
    root = Path.join(System.tmp_dir!(), "loader_runtime_#{System.unique_integer([:positive])}")
    bin_dir = Path.join(root, "erts-test/bin")
    erlexec = Path.join(bin_dir, executable_name("erlexec"))

    File.mkdir_p!(bin_dir)
    File.write!(erlexec, "")
    on_exit(fn -> File.rm_rf!(root) end)

    assert Loader.stage_executable(root, "test") == erlexec
  end

  test "uses a packaged release's start_clean boot file" do
    root = Path.join(System.tmp_dir!(), "loader_boot_#{System.unique_integer([:positive])}")
    boot = Path.join(root, "releases/1.0.0/start_clean.boot")

    File.mkdir_p!(Path.dirname(boot))
    File.write!(boot, "")
    on_exit(fn -> File.rm_rf!(root) end)

    assert Loader.stage_boot(root) == Path.rootname(boot)
  end

  defp executable_name(name), do: name <> @executable_suffix
end
