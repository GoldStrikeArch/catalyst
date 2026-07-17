defmodule CatalystDesktop.MixProject do
  use Mix.Project

  def project do
    [
      app: :catalyst_desktop,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Boots the native window. The wx/desktop integration lives behind the
  # CatalystDesktop.Application module, which only starts a Desktop.Window when
  # desktop mode is requested (env CATALYST_DESKTOP=1 or :start_window config).
  def application do
    [
      mod: {CatalystDesktop.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:catalyst_web, in_umbrella: true},
      {:desktop, "~> 1.5"}
    ]
  end
end
