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
      description_long: "Catalyst is an Elixir/OTP coding agent with a Phoenix LiveView desktop UI.",
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
        steps: [:assemble, &Desktop.Deployment.generate_installer/1]
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
      preferred_envs: [precommit: :test]
    ]
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
      {:desktop_deployment, github: "elixir-desktop/deployment", runtime: false}
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
