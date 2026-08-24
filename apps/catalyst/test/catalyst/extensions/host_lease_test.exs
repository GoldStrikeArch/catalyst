defmodule Catalyst.Extensions.HostLeaseTest do
  use ExUnit.Case, async: false

  alias Catalyst.Extensions

  @host :host_lease_test

  setup do
    on_exit(fn -> :persistent_term.erase({Extensions, :host_lease, @host}) end)

    :ok
  end

  test "readiness follows the host's live lease" do
    host = start_lease_process(:host_lease)

    Extensions.register_host(@host, host)
    assert Extensions.host_ready?(@host)

    ref = Process.monitor(host)
    Process.exit(host, :kill)
    assert_receive {:DOWN, ^ref, :process, ^host, :killed}

    refute Extensions.host_ready?(@host)
  end

  test "bootstrap reports an unavailable extension runtime" do
    server = Process.whereis(Extensions)
    assert is_pid(server)
    assert Process.unregister(Extensions)

    try do
      assert Extensions.bootstrap() == {:skipped, :extension_runtime_unavailable}
    after
      Process.register(server, Extensions)
    end
  end

  defp start_lease_process(id) do
    child_spec = %{
      id: id,
      start: {Agent, :start_link, [fn -> :ok end]},
      restart: :temporary
    }

    start_supervised!(child_spec)
  end
end
