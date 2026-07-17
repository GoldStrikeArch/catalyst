import Config

# config/runtime.exs is executed for all environments, including during
# releases. The block below is prod (packaged-app) runtime configuration.
if config_env() == :prod do
  # Local desktop app: a generated per-boot secret is fine (override with
  # SECRET_KEY_BASE for a stable one).
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))

  # Fixed loopback port. A fixed (non-zero) port keeps Desktop.Endpoint.url/0 on
  # its simple path (its dynamic-port branch assumes cowboy/ranch and breaks
  # under Bandit on Phoenix 1.8). The wx window points at this url.
  port = String.to_integer(System.get_env("PORT", "4000"))

  config :catalyst_web, CatalystWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: port],
    url: [host: "localhost", port: port, scheme: "http"],
    secret_key_base: secret_key_base

  config :catalyst, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Runtime asset rebuild (rebuild_assets / CatalystWeb.Assets) inside the packaged
  # app. The release `bundle_assets` step ships a self-contained asset workspace
  # (source + JS deps + esbuild/tailwind binaries) under the catalyst_web app dir;
  # point esbuild/tailwind at it with absolute paths resolved here at boot.
  web_dir = Application.app_dir(:catalyst_web)
  ws = Path.join(web_dir, "priv/asset_build")
  static = Path.join(web_dir, "priv/static/assets")

  config :esbuild, path: Path.join(ws, "bin/esbuild")
  config :tailwind, path: Path.join(ws, "bin/tailwind")

  config :esbuild,
    catalyst_web: [
      args: [
        "js/app.js",
        "--bundle",
        "--target=es2022",
        "--outdir=#{Path.join(static, "js")}",
        "--external:/fonts/*",
        "--external:/images/*",
        "--alias:@=."
      ],
      cd: Path.join(ws, "assets"),
      env: %{"NODE_PATH" => Path.join(web_dir, "deps")}
    ]

  config :tailwind,
    catalyst_web: [
      args: [
        "--input=assets/css/app.css",
        "--output=#{Path.join(static, "css/app.css")}"
      ],
      cd: ws
    ]
end
