defmodule Catalyst.Pack.ReleaseFilesTest do
  use ExUnit.Case, async: true

  alias Catalyst.Pack.ReleaseFiles

  test "selects the product and host pinned to each shipped release" do
    assert {:ok, cli} = ReleaseFiles.plan(:catalyst_cli, :darwin)
    assert cli.product_id == "minimal-cli"
    assert cli.host == :cli
    assert Enum.map(cli.contributions, & &1.declaration.source) == ~w(rg fd sd ast-grep)

    assert {:ok, desktop} = ReleaseFiles.plan(:catalyst_desktop, :darwin)
    assert desktop.product_id == "coding-agent"
    assert desktop.host == :desktop

    assert {:error, {:unknown_catalyst_release, :unknown}} =
             ReleaseFiles.plan(:unknown, :darwin)
  end

  test "preflights and copies executable contributions into the core app" do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst-release-files-#{System.unique_integer([:positive, :monotonic])}"
      )

    source = Path.join(root, "source/rg")
    app_dir = Path.join(root, "lib/catalyst-0.1.0")
    executable = executable("rg")
    resolver = fn "rg" -> source end

    :ok = File.mkdir_p(Path.dirname(source))
    :ok = File.write(source, "fixture")
    on_exit(fn -> File.rm_rf(root) end)

    assert [{^source, "executable `rg` from pack catalyst.tools.coding on PATH"}] =
             ReleaseFiles.checks([executable], resolver)

    assert :ok = ReleaseFiles.copy([executable], app_dir, resolver)

    target = Path.join(app_dir, "priv/bin/rg")
    assert File.read!(target) == "fixture"
    assert {:ok, %{mode: mode}} = File.stat(target)
    assert Bitwise.band(mode, 0o111) == 0o111

    assert {:error, {:release_executable_missing, "catalyst.tools.coding", "rg"}} =
             ReleaseFiles.copy([executable], app_dir, fn _source -> nil end)
  end

  defp executable(source) do
    %{
      kind: :executable,
      id: source,
      source: source,
      target: "priv/bin/#{source}",
      pack_id: "catalyst.tools.coding"
    }
  end
end
