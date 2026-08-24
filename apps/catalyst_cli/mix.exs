defmodule CatalystCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :catalyst_cli,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {CatalystCli.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:catalyst, in_umbrella: true},
      {:catalyst_features, in_umbrella: true}
    ]
  end

  # The umbrella root's `setup` alias runs `mix setup` in every child app, so
  # each app must define one (mix cmd aborts the whole run on a missing task).
  defp aliases do
    [setup: ["deps.get"]]
  end
end
