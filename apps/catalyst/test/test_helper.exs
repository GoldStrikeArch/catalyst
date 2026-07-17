# Keep session JSONL out of the real ~/.catalyst during tests.
Application.put_env(
  :catalyst,
  :sessions_root,
  Path.join(System.tmp_dir!(), "catalyst_test_sessions_#{System.unique_integer([:positive])}")
)

ExUnit.start()
