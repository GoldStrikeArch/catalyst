# Every test root (home, auth, sessions, extensions, boot marker, prompts)
# lives under the per-OS-pid tmp home configured in config/test.exs — the one
# place the test root is set. Remove the whole tree when this VM exits so
# repeated runs cannot accumulate state in tmp.
test_home = Application.fetch_env!(:catalyst, :home)

System.at_exit(fn _status -> File.rm_rf(test_home) end)

ExUnit.start()
