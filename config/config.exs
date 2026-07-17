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
  version: "0.25.4",
  catalyst_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/catalyst_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
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
