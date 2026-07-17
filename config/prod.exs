import Config

# Catalyst ships as a local desktop app served to its own wx webview over
# loopback http — not a public web server. So: localhost url, no force_ssl, and
# the runtime port/secret come from config/runtime.exs.
# No static digesting: a local single-user webview needs no cache-busting, and
# serving plain `app.js`/`app.css` lets the runtime asset rebuild (rebuild_assets)
# overwrite the served files and take effect on the next reload.
config :catalyst_web, CatalystWeb.Endpoint,
  url: [host: "localhost"]

# Open the native window when the packaged app boots.
config :catalyst_desktop, start_window: true

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
