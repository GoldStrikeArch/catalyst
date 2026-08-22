import Config

# Keep auth credentials and session logs out of the real ~/.catalyst during
# tests. Set before the :catalyst app starts so TokenStore reads this path.
# Keyed by OS pid so two concurrent `mix test` runs (a second worktree, a
# shared CI runner) can't share auth/session/extension state or delete each
# other's extension dirs mid-run.
test_tmp = Path.join(System.tmp_dir!(), "catalyst_test_#{System.pid()}")

config :catalyst,
  home: test_tmp,
  # Chaos/recovery tests intentionally kill several runtime registries inside
  # OTP's five-second restart window. Keep production's default budget intact.
  extension_runtime_max_restarts: 10,
  auth_path: Path.join(test_tmp, "auth.json"),
  sessions_root: Path.join(test_tmp, "sessions"),
  extensions_dir: Path.join(test_tmp, "extensions"),
  # Never fetch the live Codex model catalog from tests (several tests PUT
  # real-looking tokens into the TokenStore, which would arm the fetch).
  codex_live_models: false,
  # Keep the boot marker + system-prompt override out of ~/.catalyst too (a
  # stale "booting" marker in a shared location would flip test boots into
  # safe mode); short stabilization so boot marks itself ok quickly.
  boot_marker_path: Path.join(test_tmp, "boot_marker"),
  system_prompt_path: Path.join(test_tmp, "system_prompt.md"),
  prompts_dir: Path.join(test_tmp, "prompts"),
  agents_dir: Path.join(test_tmp, "agents"),
  boot_stable_ms: 50,
  # Production retains the prior generation for post-activation rollback.
  # Ordinary tests opt into that timer only when exercising its lifecycle.
  runtime_generation_stabilization_ms: 0,
  # Computer use: pin the whole grant so the advertised tool set is identical
  # on every host. The helper path stays inside test_tmp (nothing builds it),
  # and the backend is explicitly reported unavailable — tests that need the
  # granted state flip :computer_backend_available themselves.
  computer_use: false,
  computer_helper_path: Path.join(test_tmp, "bin/catalyst-input"),
  computer_backend_available: false,
  # shell_session: pin the lifecycle knobs so the suite is deterministic;
  # idle-timeout and cap tests flip these per-test with restore.
  shell_session_idle_ms: 15 * 60 * 1000,
  shell_session_max: 4

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :catalyst_web, CatalystWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "YEFSoTMJ0FlpC47T+CGpr9KXtPxk6qrA3IJ4t2rt3s2Imdw+UmHuDfLP65piqAnb",
  server: false

# Each test mount gets a fresh session; reattach is exercised explicitly.
config :catalyst_web, reattach_sessions: false

# UI recovery tests intentionally restart both the table owner and registry in
# one suite. Production retains OTP's default escalation threshold.
config :catalyst_web, ui_runtime_max_restarts: 10

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
