defmodule CatalystWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :catalyst_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {CatalystWeb.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.7"},
      {:desktop, "~> 1.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      # Runtime in dev AND prod (not test): the packaged app rebuilds assets at
      # runtime (CatalystWeb.Assets). Kept out of :test so suites never shell out.
      {:esbuild, "~> 0.10", runtime: Mix.env() != :test},
      {:tailwind, "~> 0.3", runtime: Mix.env() != :test},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:catalyst, in_umbrella: true},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind catalyst_web", "esbuild catalyst_web"],
      # No phx.digest: the desktop app serves plain app.js/app.css so the
      # runtime asset rebuild can overwrite the served files in place. Digested
      # copies and .gz siblings would shadow the rebuilt files (Plug.Static
      # prefers *.gz when gzip is on) and silently break self-modification.
      "assets.deploy": [
        "tailwind catalyst_web --minify",
        "esbuild catalyst_web --minify"
      ]
    ]
  end
end
