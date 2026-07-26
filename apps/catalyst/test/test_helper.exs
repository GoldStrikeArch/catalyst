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

ExUnit.start()
