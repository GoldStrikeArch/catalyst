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
end
