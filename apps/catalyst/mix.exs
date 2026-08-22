defmodule Catalyst.MixProject do
  use Mix.Project

  def project do
    [
      app: :catalyst,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      # Coverage measures shipped code only: test/support harnesses (stub
      # providers, fixtures, case templates) are test-env-only and covering
      # them with tests would be circular.
      test_coverage: [
        ignore_modules: [
          ~r/^Catalyst\.Test\./,
          ~r/^Catalyst\.Flex\./,
          ~r/^Catalyst\.ExtensionsFixtures/,
          Catalyst.LLM.Demo,
          Catalyst.EnvCase
        ]
      ],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Catalyst.Application, []},
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
      {:phoenix_pubsub, "~> 2.2"},
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.11"},
      {:finch, "~> 0.23"},
      # Codex websocket transport (Mint is already in the tree via Finch).
      {:mint_web_socket, "~> 1.0"},
      {:req, "~> 0.7"},
      # `fetch` reduces HTML to readable text. Floki's default mochiweb backend
      # is pure Erlang, so this adds no NIF and no packaging risk.
      {:floki, "~> 0.38"},
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.20"},
      # Test-only: local websocket server for the Codex websocket client tests.
      {:websock_adapter, "~> 0.6", only: :test}
    ] ++ platform_deps()
  end

  # MuonTrap's process-group wrapper uses POSIX headers and cannot compile on
  # Windows. Exec.bash/2 reports that platform as unsupported instead of
  # weakening its process-tree cancellation contract.
  defp platform_deps do
    case :os.type() do
      {:unix, _name} -> [{:muontrap, "~> 2.0"}]
      {_family, _name} -> []
    end
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
