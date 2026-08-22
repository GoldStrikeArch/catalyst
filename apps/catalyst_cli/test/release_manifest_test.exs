defmodule CatalystCli.ReleaseManifestTest do
  use ExUnit.Case, async: false

  @moduletag :release

  # Apps that must ship in the headless CLI release.
  @required_apps ~w(catalyst catalyst_cli jason req finch phoenix_pubsub bandit plug)

  # UI/desktop stack that must NOT leak into the headless CLI release.
  @forbidden_apps ~w(catalyst_web catalyst_desktop desktop phoenix phoenix_live_view
                     phoenix_html esbuild tailwind wx)

  @tag timeout: 600_000
  test "R2: the plain CLI release manifest pins expected contents" do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_release_manifest_#{System.pid()}_#{System.unique_integer([:positive, :monotonic])}"
      )

    release_path = Path.join(root, "release")
    umbrella_root = Path.expand("../../..", __DIR__)
    on_exit(fn -> File.rm_rf!(root) end)

    mix = System.find_executable("mix") || flunk("mix executable is unavailable")

    {build_output, build_status} =
      System.cmd(
        mix,
        ["release", "catalyst_cli", "--overwrite", "--path", release_path],
        cd: umbrella_root,
        env: [{"MIX_ENV", "prod"}, {"CATALYST_RELEASE_PLAIN", "1"}],
        stderr_to_stdout: true
      )

    assert build_status == 0, "plain release build failed:\n#{build_output}"

    # Top-level layout: a self-contained OTP release.
    executable = Path.join([release_path, "bin", "catalyst_cli"])
    assert File.regular?(executable), "missing release entrypoint bin/catalyst_cli"
    assert File.dir?(Path.join(release_path, "releases")), "missing releases/ metadata dir"
    assert Path.wildcard(Path.join(release_path, "erts-*")) != [], "release did not bundle ERTS"

    apps = shipped_apps(release_path)

    for app <- @required_apps do
      assert app in apps,
             "expected #{app} in release lib, shipped apps: #{inspect(Enum.sort(apps))}"
    end

    for app <- @forbidden_apps do
      refute app in apps, "headless CLI release must not ship #{app}"
    end

    [core_dir] = Path.wildcard(Path.join(release_path, "lib/catalyst-*"))

    assert {:ok, executables} =
             Catalyst.Pack.ReleaseFiles.executables(
               :catalyst_cli,
               Catalyst.Pack.ReleaseFiles.platform()
             )

    for executable <- executables do
      target = Path.join(core_dir, executable.target)

      assert File.regular?(target),
             "missing pack executable #{executable.pack_id}:#{executable.id} at #{target}"

      assert {:ok, %{mode: mode}} = File.stat(target)
      assert Bitwise.band(mode, 0o111) != 0, "pack executable is not executable: #{target}"
    end
  end

  defp shipped_apps(release_path) do
    release_path
    |> Path.join("lib")
    |> File.ls!()
    |> Enum.map(fn dir -> dir |> String.split("-") |> hd() end)
  end
end
