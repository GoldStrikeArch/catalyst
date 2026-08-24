defmodule CatalystFeatures.MixProject do
  use Mix.Project

  def project do
    [
      app: :catalyst_features,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: [setup: ["deps.get"]],
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:catalyst, in_umbrella: true},
      {:floki, "~> 0.38"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.7"}
    ] ++ platform_deps()
  end

  defp platform_deps do
    case :os.type() do
      {:unix, _name} -> [{:muontrap, "~> 2.0"}]
      {_family, _name} -> []
    end
  end
end
