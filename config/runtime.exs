import Config

# config/runtime.exs is executed for all environments, including during
# releases. The block below is prod (packaged-app) runtime configuration.
if config_env() == :prod do
  # Everything below configures :catalyst_web (endpoint + runtime asset
  # rebuild). The catalyst_cli release ships without :catalyst_web, where
  # Application.app_dir/1 would raise and abort the binary during runtime-config
  # evaluation, so skip the whole section when the app isn't in the release.
  case :code.lib_dir(:catalyst_web) do
    {:error, :bad_name} ->
      :ok

    _ ->
      # Local desktop app: a generated per-boot secret is fine (override with
      # SECRET_KEY_BASE for a stable one).
      secret_key_base =
        System.get_env("SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))

      # Port 0: the OS assigns a free loopback port, so the packaged app still
      # boots when 4000 is taken (another Phoenix dev server, a second Catalyst
      # instance). This works under Bandit because the endpoint overrides
      # get_dynamic_port/1 via server_info/1, and Desktop.Window resolves the
      # real URL through &CatalystWeb.Endpoint.url/0 once the listener is
      # bound. Set PORT to pin a fixed port instead.
      port =
        case System.get_env("PORT", "0") |> Integer.parse() do
          {p, ""} when p >= 0 and p <= 65535 -> p
          _ -> 0
        end

      config :catalyst_web, CatalystWeb.Endpoint,
        http: [ip: {127, 0, 0, 1}, port: port],
        url: [host: "localhost", port: port, scheme: "http"],
        secret_key_base: secret_key_base

      # Runtime asset rebuild inputs inside the packaged app. `bundle_assets` ships a
      # self-contained source/toolchain seed here; CatalystWeb.RuntimeAssets copies the
      # source to CATALYST_HOME and overrides these output arguments for each immutable
      # candidate generation, so the paths below are never mutated by a runtime build.
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
end
