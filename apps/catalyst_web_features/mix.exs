defmodule CatalystWebFeatures.MixProject do
  use Mix.Project

  def project do
    [
      app: :catalyst_web_features,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: [setup: ["deps.get"]],
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:catalyst_features, in_umbrella: true},
      {:catalyst_web, in_umbrella: true},
      {:phoenix_live_view, "~> 1.2.10"}
    ]
  end
end
