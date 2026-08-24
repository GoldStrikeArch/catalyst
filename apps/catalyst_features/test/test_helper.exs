test_home = Application.fetch_env!(:catalyst, :home)
System.at_exit(fn _status -> File.rm_rf(test_home) end)

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

ExUnit.start(exclude: [:live_wire, :computer, :clipboard])
