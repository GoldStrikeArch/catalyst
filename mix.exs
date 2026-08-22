defmodule Catalyst.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      package: package(),
      dialyzer: dialyzer(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Desktop app metadata consumed by desktop_deployment (Desktop.Deployment.Package).
  # `app_name` is required for an umbrella (the root has no :app of its own).
  defp package do
    [
      name: "Catalyst",
      name_long: "Catalyst",
      description: "A coding agent for your desktop",
      description_long:
        "Catalyst is an Elixir/OTP coding agent with a Phoenix LiveView desktop UI.",
      icon: "apps/catalyst_desktop/priv/icon.png",
      category_macos: "public.app-category.developer-tools",
      identifier: "dev.catalyst.app",
      app_name: :catalyst_desktop
    ]
  end

  defp releases do
    [
      # The packaged macOS GUI app (wx + LiveView). Build with:
      #   MIX_ENV=prod mix assets.deploy && mix desktop.installer
      # (or: MIX_ENV=prod mix release catalyst_desktop --overwrite)
      catalyst_desktop: [
        applications: [
          catalyst_desktop: :permanent,
          runtime_tools: :permanent,
          ssl: :permanent
        ],
        steps: [
          :assemble,
          &release_preflight!/1,
          &bundle_assets/1,
          &Desktop.Deployment.generate_installer/1,
          &native_macos_launcher/1
        ]
      ],
      # Headless self-contained binary of Catalyst's core (no wx) via Burrito.
      # Build with: MIX_ENV=prod mix release catalyst_cli
      catalyst_cli: [
        applications: [catalyst_cli: :permanent],
        # CATALYST_RELEASE_PLAIN=1 skips the Burrito wrap (needs zig): the plain
        # assembled release is what the release smoke tier boots.
        steps:
          [:assemble] ++
            if(System.get_env("CATALYST_RELEASE_PLAIN"), do: [], else: [&Burrito.wrap/1]),
        burrito: [
          targets: [
            macos: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        dialyzer: :dev,
        "test.flex": :test,
        "test.release": :test,
        "test.computer": :test
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix]
    ]
  end

  @fast_tools ~w(rg fd sd ast-grep)

  # Deterministic packaging preflight (desktop release). Every input the
  # bundling steps below copy into the release must exist on the build host,
  # otherwise the app would assemble fine but ship without runtime asset
  # rebuild or the fast search/replace tools. Collect ALL missing inputs and
  # fail once with the full list; dev/test flows never run this (it is a
  # release step).
  defp release_preflight!(release) do
    checks =
      [
        {webapp_dir(release), "catalyst_web app dir under #{release.path}/lib"},
        {core_dir(release), "catalyst core app dir under #{release.path}/lib"},
        {esbuild_bin(),
         "esbuild standalone binary under #{build_root()} (run `mix assets.setup`)"},
        {tailwind_bin(),
         "tailwind standalone binary under #{build_root()} (run `mix assets.setup`)"}
      ] ++
        for exe <- @fast_tools do
          {System.find_executable(exe), "fast tool `#{exe}` on PATH"}
        end ++ computer_helper_checks()

    case for {nil, label} <- checks, do: label do
      [] ->
        release

      missing ->
        raise """
        catalyst_desktop release preflight failed — missing required packaging inputs:

        #{Enum.map_join(missing, "\n", &("  - " <> &1))}
        """
    end
  end

  # The native computer-use input helper is compiled during bundling
  # (bundle_computer_helper/1), so its inputs are preflight-checked on Darwin.
  # Non-Darwin desktop builds ship without it by design (macOS-only feature).
  @computer_helper_src "rel/macos/computer_helper.m"

  defp computer_helper_checks do
    case :os.type() do
      {:unix, :darwin} ->
        [
          {if(File.exists?(@computer_helper_src), do: @computer_helper_src),
           "computer-use helper source #{@computer_helper_src}"},
          {System.find_executable("cc"), "C compiler `cc` on PATH (Xcode command line tools)"}
        ]

      _other ->
        []
    end
  end

  defp webapp_dir(release),
    do: release.path |> Path.join("lib/catalyst_web-*") |> Path.wildcard() |> List.first()

  defp core_dir(release),
    do: release.path |> Path.join("lib/catalyst-*") |> Path.wildcard() |> List.first()

  # Parent of the per-env build dir; esbuild/tailwind install their standalone
  # binaries there. Derived from Mix.Project so MIX_BUILD_ROOT/:build_path
  # overrides keep working (a literal "_build" would not).
  defp build_root, do: Path.dirname(Mix.Project.build_path())

  defp esbuild_bin, do: build_root() |> Path.join("esbuild-*") |> Path.wildcard() |> List.first()

  defp tailwind_bin,
    do: build_root() |> Path.join("tailwind-*") |> Path.wildcard() |> List.first()

  # Release step (desktop): bundle a self-contained asset workspace so the packaged
  # app can rebuild CSS/JS at runtime (CatalystWeb.Assets / the rebuild_assets tool).
  # See the prod block in config/runtime.exs for the paths these are wired to.
  # Runs after release_preflight!/1, so all inputs are known to exist.
  defp bundle_assets(release) do
    webapp = webapp_dir(release)
    ws = Path.join(webapp, "priv/asset_build")
    deps = Path.join(webapp, "deps")
    File.mkdir_p!(Path.join(ws, "bin"))
    File.mkdir_p!(Path.join(ws, "lib"))
    File.mkdir_p!(deps)

    # Asset source (css/js/vendor) + lib source (for tailwind's @source scanning).
    File.cp_r!("apps/catalyst_web/assets", Path.join(ws, "assets"))
    File.cp_r!("apps/catalyst_web/lib/catalyst_web", Path.join(ws, "lib/catalyst_web"))

    # JS deps esbuild resolves via NODE_PATH, heroicons (its tailwind plugin reads
    # SVGs via a path relative to vendor/), and the generated colocated hooks.
    for d <- ~w(phoenix phoenix_html phoenix_live_view heroicons) do
      File.cp_r!("deps/#{d}", Path.join(deps, d))
    end

    colocated = Path.join(Mix.Project.build_path(), "phoenix-colocated")
    if File.dir?(colocated), do: File.cp_r!(colocated, Path.join(deps, "phoenix-colocated"))

    # esbuild + tailwind standalone binaries.
    cp_bin!(esbuild_bin(), Path.join(ws, "bin/esbuild"))
    cp_bin!(tailwind_bin(), Path.join(ws, "bin/tailwind"))

    # Also scan the user's runtime extensions dir so Tailwind classes used by
    # runtime-created UI components get compiled. The build machine's path is
    # only a placeholder: the marker comment lets the runtime rebuild
    # (CatalystWeb.Assets) rewrite this line for the machine the app actually
    # runs on before invoking tailwind.
    ext_dir = Path.expand("~/.catalyst/extensions")

    File.write!(
      Path.join(ws, "assets/css/app.css"),
      ~s[\n/* catalyst:extensions-source */\n@source "#{ext_dir}";\n],
      [:append]
    )

    IO.puts("bundle_assets: workspace at #{ws}")

    bundle_fast_tools(release)
    bundle_computer_helper(release)
    release
  end

  # Release step (desktop): compile + ad-hoc sign the native computer-use input
  # helper into the core app's priv/bin, mirroring `mix catalyst.computer.build`.
  # Runs inside bundle_assets so the binary lands in the bundle before
  # generate_installer/1 seals it. Signed here explicitly: the launcher step's
  # comment records that codesign fails when it seals a bundle containing an
  # unsigned executable. macOS-only; other hosts skip (the backend is
  # unavailable there anyway).
  defp bundle_computer_helper(release) do
    case :os.type() do
      {:unix, :darwin} ->
        dest = release |> core_dir() |> Path.join("priv/bin/catalyst-input")
        File.mkdir_p!(Path.dirname(dest))

        cmd!(
          "cc",
          ["-arch", "arm64", "-O2", "-fobjc-arc", "-Wno-deprecated-declarations"] ++
            ~w(-framework ApplicationServices -framework Carbon -framework Foundation
               -framework AppKit) ++ ["-o", dest, @computer_helper_src]
        )

        File.chmod!(dest, 0o755)
        cmd!("codesign", ["--force", "-s", "-", dest])
        IO.puts("bundle_computer_helper: built and signed #{dest}")
        :ok

      _other ->
        IO.puts("bundle_computer_helper: not macOS, skipping (macOS-only feature)")
        :ok
    end
  end

  # Release step (desktop): give the .app a native arm64 main executable.
  #
  # desktop_deployment makes Contents/MacOS/run (a #!/bin/bash script) the
  # CFBundleExecutable. A script has no Mach-O header, so macOS LaunchServices
  # mislabels the bundle "Intel" and launches the x86_64 slice of /bin/bash ->
  # the Rosetta / "Intel app" prompt, even though everything we ship is arm64.
  #
  # We compile a tiny native arm64 launcher (rel/macos/launcher.c) that execs the
  # existing `run` script, point CFBundleExecutable at it, then rebuild the .dmg
  # from the fixed app so a shared image is native too. No-op off macOS / without cc.
  defp native_macos_launcher(release) do
    app = macos_app_root(release)

    cond do
      :os.type() != {:unix, :darwin} ->
        release

      System.find_executable("cc") == nil ->
        IO.warn("native_macos_launcher: cc not found, leaving script launcher")
        release

      app == nil or not File.dir?(app) ->
        IO.warn("native_macos_launcher: #{package()[:name]}.app not found, skipping")
        release

      true ->
        name = package()[:name]
        launcher = Path.join([app, "Contents/MacOS", name])
        recovery_host = Path.join([app, "Contents/MacOS", "catalyst-recovery-host"])
        plist = Path.join(app, "Contents/Info.plist")

        File.cp!("rel/recovery_host", recovery_host)
        File.chmod!(recovery_host, 0o755)
        cmd!("cc", ["-arch", "arm64", "-O2", "-o", launcher, "rel/macos/launcher.c"])
        File.chmod!(launcher, 0o755)
        # Ad-hoc sign the launcher as a standalone Mach-O *before* it becomes the
        # bundle's main executable. If we flipped CFBundleExecutable first, codesign
        # would treat this path as the app's main exec and try to seal the whole
        # bundle, which fails on the unsigned `run` script.
        cmd!("codesign", ["--force", "-s", "-", launcher])
        cmd!("plutil", ["-replace", "CFBundleExecutable", "-string", name, plist])

        # Computer use: Automation (Apple Events) prompts require a usage
        # string in the bundle's Info.plist. desktop_deployment generates the
        # plist, so it is patched here — the one existing place we already
        # rewrite it (plutil -replace inserts when the key is absent).
        cmd!("plutil", [
          "-replace",
          "NSAppleEventsUsageDescription",
          "-string",
          "Catalyst uses Apple Events to control and read other applications " <>
            "when computer use is enabled.",
          plist
        ])

        IO.puts("native_macos_launcher: installed native arm64 launcher (#{name})")

        rebuild_installers(release, app)
        release
    end
  end

  # _build/<env>/Catalyst.app — mirrors Package.MacOS: build_root = release.path/../..
  defp macos_app_root(release) do
    build_root = Path.expand(Path.join([release.path, "..", ".."]))
    Path.join(build_root, "#{package()[:name]}.app")
  end

  # Rebuild the distributables (.dmg/.pkg) from the fixed app so a shared image is
  # native too — generate_installer built them from the pre-launcher app. Best-effort:
  # warns instead of failing the release (the runnable .app is already correct).
  defp rebuild_installers(release, app) do
    name = package()[:name]
    build_root = Path.expand(Path.join([release.path, "..", ".."]))
    dmg = Path.join(build_root, "#{name}-#{release.version}.dmg")
    pkg = Path.join(build_root, "#{name}-#{release.version}.pkg")
    volume = Path.join("/Volumes", name)

    if File.exists?(volume), do: System.cmd("hdiutil", ["detach", volume, "-force"])

    if File.exists?(dmg) do
      File.rm(dmg)

      rebuild!(
        "dmg",
        "hdiutil",
        ["create", "-srcfolder", app, "-volname", name, "-ov", "-format", "ULFO", dmg]
      )
    end

    if File.exists?(pkg) do
      File.rm(pkg)
      rebuild!("pkg", "productbuild", ["--component", app, "/Applications", pkg])
    end
  end

  defp rebuild!(label, exe, args) do
    case System.cmd(exe, args, stderr_to_stdout: true) do
      {_, 0} -> IO.puts("native_macos_launcher: rebuilt #{label}")
      {out, code} -> IO.warn("native_macos_launcher: #{label} rebuild failed (#{code}): #{out}")
    end
  end

  defp cmd!(exe, args) do
    case System.cmd(exe, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> raise "#{exe} #{Enum.join(args, " ")} failed (#{code}):\n#{out}"
    end
  end

  # Bundle the fast-tool binaries (rg/fd/sd/ast-grep) into the core app's priv/bin
  # so grep/find/replace/ast_grep work in the packaged app (a GUI .app has a minimal
  # PATH). release_preflight!/1 already verified they exist on the build host.
  defp bundle_fast_tools(release) do
    bindir = release |> core_dir() |> Path.join("priv/bin")
    File.mkdir_p!(bindir)

    for exe <- @fast_tools do
      src =
        System.find_executable(exe) ||
          raise "bundle_fast_tools: `#{exe}` disappeared from PATH after preflight"

      cp_bin!(src, Path.join(bindir, exe))
    end

    :ok
  end

  defp cp_bin!(src, dest) do
    File.cp!(src, dest)
    File.chmod!(dest, 0o755)
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options.
  #
  # Dependencies listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp deps do
    [
      # Required to run "mix format" on ~H/.heex files from the umbrella root
      {:phoenix_live_view, ">= 0.0.0"},
      # Packaging the headless core into a self-contained binary.
      {:burrito, "~> 1.5"},
      # Packaging the wx GUI into a macOS .app/.dmg (bundles wxWidgets dylibs).
      # Pinned: the release steps depend on its internals (Package.MacOS build
      # layout, the `run` launcher script) — an unpinned deps.update could
      # silently break the installer.
      {:desktop_deployment,
       github: "elixir-desktop/deployment",
       ref: "73fed3e6a5096724cb6af11ff9a5b5c79a2c7186",
       runtime: false},
      # Static analysis via `mix dialyzer`.
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  #
  # Aliases listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --check-unused", "format", "test"],
      # flexibility tier only (it also runs as part of plain `mix test`)
      "test.flex": [
        "do --app catalyst --app catalyst_web cmd mix test --only flexibility"
      ],
      # release smoke tier (excluded from plain `mix test`; builds a real release)
      "test.release": ["do --app catalyst_cli cmd mix test --only release"],
      # real-desktop computer-use tier (excluded from plain `mix test`; drives
      # the built helper against its own --test-target window — needs
      # Accessibility + Screen Recording granted to the test runner)
      "test.computer": ["do --app catalyst cmd mix test --only computer"]
    ]
  end
end
