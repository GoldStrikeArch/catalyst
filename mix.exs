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
        steps: [:assemble, &bundle_assets/1, &Desktop.Deployment.generate_installer/1]
      ],
      # Headless self-contained binary of Catalyst's core (no wx) via Burrito.
      # Build with: MIX_ENV=prod mix release catalyst_cli
      catalyst_cli: [
        applications: [catalyst_cli: :permanent],
        steps: [:assemble, &Burrito.wrap/1],
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
      preferred_envs: [precommit: :test, dialyzer: :dev]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix]
    ]
  end

  # Release step (desktop): bundle a self-contained asset workspace so the packaged
  # app can rebuild CSS/JS at runtime (CatalystWeb.Assets / the rebuild_assets tool).
  # See the prod block in config/runtime.exs for the paths these are wired to.
  defp bundle_assets(release) do
    webapp = release.path |> Path.join("lib/catalyst_web-*") |> Path.wildcard() |> List.first()

    if webapp do
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

      colocated = "_build/#{Mix.env()}/phoenix-colocated"
      if File.dir?(colocated), do: File.cp_r!(colocated, Path.join(deps, "phoenix-colocated"))

      # esbuild + tailwind standalone binaries.
      cp_bin!(Path.wildcard("_build/esbuild-*") |> List.first(), Path.join(ws, "bin/esbuild"))
      cp_bin!(Path.wildcard("_build/tailwind-*") |> List.first(), Path.join(ws, "bin/tailwind"))

      # Also scan the user's runtime extensions dir so Tailwind classes used by
      # runtime-created UI components get compiled (same machine for a local app).
      ext_dir = Path.expand("~/.catalyst/extensions")
      File.write!(Path.join(ws, "assets/css/app.css"), ~s/\n@source "#{ext_dir}";\n/, [:append])

      IO.puts("bundle_assets: workspace at #{ws}")
    else
      IO.warn("bundle_assets: catalyst_web app dir not found under #{release.path}")
    end

    bundle_fast_tools(release)
    release
  end

  # Bundle the fast-tool binaries (rg/fd/sd/ast-grep) into the core app's priv/bin
  # so grep/find/replace/ast_grep work in the packaged app (a GUI .app has a minimal
  # PATH). Resolved from the build host; skipped if not installed.
  defp bundle_fast_tools(release) do
    coreapp = release.path |> Path.join("lib/catalyst-*") |> Path.wildcard() |> List.first()

    if coreapp do
      bindir = Path.join(coreapp, "priv/bin")
      File.mkdir_p!(bindir)

      for exe <- ~w(rg fd sd ast-grep) do
        case System.find_executable(exe) do
          nil -> IO.puts("bundle_fast_tools: #{exe} not on PATH, skipping")
          src -> cp_bin!(src, Path.join(bindir, exe))
        end
      end
    end

    :ok
  end

  defp cp_bin!(nil, _dest), do: :ok

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
      {:desktop_deployment, github: "elixir-desktop/deployment", runtime: false},
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
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
