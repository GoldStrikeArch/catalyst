import Config

# Keep auth credentials and session logs out of the real ~/.catalyst during
# tests. Set before the :catalyst app starts so TokenStore reads this path.
# Keyed by OS pid so two concurrent `mix test` runs (a second worktree, a
# shared CI runner) can't share auth/session/extension state or delete each
# other's extension dirs mid-run.
test_tmp = Path.join(System.tmp_dir!(), "catalyst_test_#{System.pid()}")

# LiveView tests drive full turns offline: the chat's (Codex-shaped) sessions
# stream through the input-aware Demo provider instead of the network.
config :catalyst_web, codex_provider_mod: Catalyst.LLM.Demo

config :catalyst,
  auth_path: Path.join(test_tmp, "auth.json"),
  sessions_root: Path.join(test_tmp, "sessions"),
  extensions_dir: Path.join(test_tmp, "extensions"),
  # Keep the boot marker + system-prompt override out of ~/.catalyst too (a
  # stale "booting" marker in a shared location would flip test boots into
  # safe mode); short stabilization so boot marks itself ok quickly.
  boot_marker_path: Path.join(test_tmp, "boot_marker"),
  system_prompt_path: Path.join(test_tmp, "system_prompt.md"),
  boot_stable_ms: 50

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :catalyst_web, CatalystWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "YEFSoTMJ0FlpC47T+CGpr9KXtPxk6qrA3IJ4t2rt3s2Imdw+UmHuDfLP65piqAnb",
  server: false

# Each test mount gets a fresh session; reattach is exercised explicitly.
config :catalyst_web, reattach_sessions: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
