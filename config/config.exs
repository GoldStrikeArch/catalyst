# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

config :catalyst_web,
  generators: [context_app: :catalyst]

# Computer use is off by default: with it on, the agent drives the machine the
# way a person does, with no sandbox. A session opts in per run
# (`Session.Server.configure(pid, opts: [computer_use: true])`, or the header
# toggle); this is only the fallback when the session says nothing. The grant
# additionally requires a usable backend — see
# `Catalyst.Tools.Computer.Availability`, which resolves the native input
# helper from `:computer_helper_path` (default: `<priv>/bin/catalyst-input`).
config :catalyst, computer_use: false

# Optional screenshot pruning for computer-use sessions: `:all` keeps every
# screenshot in the request context; an integer N replaces all but the last N
# screenshot images with text placeholders before each LLM call (a
# transform_context hook — see `Catalyst.Tools.Computer.Screenshots` for the
# delta-upload and durable-transcript costs of turning this on).
config :catalyst, computer_screenshot_retain: :all

# shell_session (PTY shells held open across turns; gated behind the same
# :computer_use capability): idle shells are closed after this many ms of no
# tool interaction, and at most this many shells run concurrently (global —
# one machine, one pool of PTYs).
config :catalyst,
  shell_session_idle_ms: 15 * 60 * 1000,
  shell_session_max: 4

# Local ACP agents are externally installed executables and are never downloaded
# by Catalyst. The providerless Claude Code workflow is registered by the
# immutable `external_agents` bundled extension.
config :catalyst,
  acp_agents: [
    %{
      "id" => "claude",
      "name" => "Claude ACP",
      "command" => "claude-agent-acp",
      "args" => [],
      "env" => %{},
      "adapter" => "claude"
    }
  ]

# Configures the endpoint
config :catalyst_web, CatalystWeb.Endpoint,
  # Always serve: the desktop shell boots via `mix run`/`mix release` (not
  # `mix phx.server`), so the HTTP listener must come up on its own for the
  # webview to connect. Overridden to `false` in config/test.exs.
  server: true,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CatalystWeb.ErrorHTML, json: CatalystWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Catalyst.PubSub,
  live_view: [signing_salt: "b/bGCcEl"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  catalyst_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/catalyst_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  catalyst_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/catalyst_web", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
