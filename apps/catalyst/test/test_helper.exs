# Every test root (home, auth, sessions, extensions, boot marker, prompts)
# lives under the per-OS-pid tmp home configured in config/test.exs — the one
# place the test root is set. Remove the whole tree when this VM exits so
# repeated runs cannot accumulate state in tmp.
test_home = Application.fetch_env!(:catalyst, :home)

System.at_exit(fn _status -> File.rm_rf(test_home) end)

# Application startup deliberately publishes extension/hook readiness only
# after the supervised guide → reseed → load workflow. Do not let unrelated
# async tests race that observable boundary.
await_extension_bootstrap = fn await_extension_bootstrap, attempts ->
  case Process.whereis(Catalyst.Extensions) do
    nil ->
      :ok

    _pid ->
      case :sys.get_state(Catalyst.Extensions) do
        %{bootstrap: :complete} ->
          :ok

        _not_ready when attempts > 0 ->
          receive do
          after
            10 -> await_extension_bootstrap.(await_extension_bootstrap, attempts - 1)
          end

        state ->
          raise "extension bootstrap did not complete before tests: #{inspect(state)}"
      end
  end
end

:ok = await_extension_bootstrap.(await_extension_bootstrap, 500)

# `:live_wire` is an opt-in tier: it makes a REAL Codex request using the
# credentials in ~/.catalyst/auth.json. Run it deliberately with
# `mix test --only live_wire`, never as part of the ordinary suite.
#
# `:computer` is the opt-in real-desktop tier (`mix test.computer`): it drives
# the built catalyst-input helper against its own --test-target window, so it
# needs a GUI session plus Accessibility + Screen Recording granted to the
# test runner's TCC subject (the terminal under `mix test`).
#
# `:clipboard` is the opt-in destructive-pasteboard tier: it overwrites the
# REAL macOS pasteboard and can only save/restore the plain-text flavor — an
# image, a file promise, or any other flavor the developer had copied is
# destroyed. Run it deliberately with `mix test --only clipboard`.
ExUnit.start(exclude: [:live_wire, :computer, :clipboard])
