defmodule Catalyst.Extensions.HostLeaseTest do
  use ExUnit.Case, async: false

  alias Catalyst.Extensions

  @host :host_lease_test
  @roles [:application, :registry]

  setup do
    on_exit(fn ->
      Enum.each(@roles, &:persistent_term.erase({Extensions, :host_lease, @host, &1}))
    end)

    :ok
  end

  test "readiness requires live application and registry leases" do
    application = start_lease_process(:host_lease_application)
    registry = start_lease_process(:host_lease_registry)

    Extensions.register_host(@host, :application, application)
    refute Extensions.host_ready?(@host)

    Extensions.register_host(@host, :registry, registry)
    assert Extensions.host_ready?(@host)

    ref = Process.monitor(registry)
    Process.exit(registry, :kill)
    assert_receive {:DOWN, ^ref, :process, ^registry, :killed}

    refute Extensions.host_ready?(@host)
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
