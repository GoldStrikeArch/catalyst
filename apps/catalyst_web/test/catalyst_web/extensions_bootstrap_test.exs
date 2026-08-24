defmodule CatalystWeb.ExtensionsBootstrapTest do
  use ExUnit.Case, async: false

  alias Catalyst.Extensions
  alias Catalyst.Extensions.BootGuard
  alias CatalystWeb.UI.Registry

  @test_pid_key :extensions_bootstrap_test_pid
  @page "bootstrap-probe"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_web_bootstrap_#{System.unique_integer([:positive, :monotonic])}"
      )

    extensions_dir = Path.join(root, "extensions")
    previous_dir = Application.fetch_env(:catalyst, :extensions_dir)
    previous_safe_mode = Application.fetch_env(:catalyst, :safe_mode)
    previous_test_pid = Application.fetch_env(:catalyst_web, @test_pid_key)
    previous_lease = host_lease()

    File.mkdir_p!(extensions_dir)
    Application.put_env(:catalyst, :extensions_dir, extensions_dir)
    Application.put_env(:catalyst, :safe_mode, false)
    Application.put_env(:catalyst_web, @test_pid_key, self())
    write_probe(extensions_dir)
    erase_web_leases()
    BootGuard.mark_ok()

    on_exit(fn ->
      restore_env(:catalyst, :extensions_dir, previous_dir)
      restore_env(:catalyst, :safe_mode, previous_safe_mode)
      restore_env(:catalyst_web, @test_pid_key, previous_test_pid)
      restore_lease(previous_lease)
      BootGuard.mark_ok()

      _replacement = restart_extensions!()
      await_bootstrap_complete!()
      File.rm_rf!(root)
    end)

    replacement = restart_extensions!()
    assert %{bootstrap: :waiting} = :sys.get_state(replacement)
    assert Extensions.boot_status() == {:waiting_for_host, :web}

    {:ok, extensions_dir: extensions_dir}
  end

  test "web bootstrap waits for a live lease and runs setup exactly once" do
    assert Application.spec(:catalyst_web, :vsn)
    assert {:skipped, {:host_not_ready, :web}} = Extensions.bootstrap()
    refute_received {:bootstrap_probe_setup, _pid}
    assert Registry.fetch_page(@page) == :error

    stale_host = start_lease!(:bootstrap_stale_host)
    Extensions.register_host(:web, stale_host)

    stale_ref = Process.monitor(stale_host)
    Process.exit(stale_host, :kill)
    assert_receive {:DOWN, ^stale_ref, :process, ^stale_host, :killed}
    assert {:skipped, {:host_not_ready, :web}} = Extensions.bootstrap()

    host = start_lease!(:bootstrap_host)
    Extensions.register_host(:web, host)
    assert :ok = Extensions.bootstrap()

    # Generous window: the probe compiles + runs setup in a background
    # bootstrap task, which can exceed assert_receive's 100ms default when
    # the suite runs after the core apps in one VM.
    assert_receive {:bootstrap_probe_setup, setup_pid}, 2_000
    assert is_pid(setup_pid)
    await_bootstrap_complete!()
    assert {:ok, {Catalyst.Ext.BootstrapProbePage, :render}} = Registry.fetch_page(@page)

    assert :ok = Extensions.bootstrap()
    assert :ok = Extensions.bootstrap()
    refute_receive {:bootstrap_probe_setup, _second_setup}, 50
  end

  test "a restart automatically bootstraps when persisted web leases remain live" do
    register_live_web_leases()

    replacement = restart_extensions!()
    assert %{bootstrap: phase} = :sys.get_state(replacement)
    assert phase in [:running, :complete]

    # Same generous window as above: setup runs in the background boot load.
    assert_receive {:bootstrap_probe_setup, _setup_pid}, 2_000
    await_bootstrap_complete!()
    assert {:ok, {Catalyst.Ext.BootstrapProbePage, :render}} = Registry.fetch_page(@page)
    refute_receive {:bootstrap_probe_setup, _second_setup}, 50
  end

  test "an explicit successful load completes a pending bootstrap without rerunning setup" do
    assert {:ok, %{failed: []}} = Extensions.load_all()
    assert_receive {:bootstrap_probe_setup, _setup_pid}, 2_000
    await_bootstrap_complete!()

    register_live_web_leases()
    assert :ok = Extensions.bootstrap()
    refute_receive {:bootstrap_probe_setup, _second_setup}, 50
    assert {:ok, {Catalyst.Ext.BootstrapProbePage, :render}} = Registry.fetch_page(@page)
  end

  test "safe mode and failed boot loads still publish hook readiness", %{
    extensions_dir: extensions_dir
  } do
    Application.put_env(:catalyst, :safe_mode, true)
    safe_server = restart_extensions!()

    await_bootstrap_complete!()
    assert %{bootstrap: :complete} = :sys.get_state(safe_server)
    assert Extensions.boot_status() == {:safe_mode, :env}
    assert Catalyst.Hooks.runtime_ready?()
    refute_received {:bootstrap_probe_setup, _setup_pid}

    Application.put_env(:catalyst, :safe_mode, false)
    File.write!(Path.join(extensions_dir, "bootstrap_probe.ex"), "not valid Elixir @@@")
    register_live_web_leases()
    BootGuard.mark_ok()
    failed_server = restart_extensions!()

    await_bootstrap_complete!()
    assert %{bootstrap: :complete} = :sys.get_state(failed_server)
    assert match?({:load_failed, _reason}, Extensions.boot_status())
    assert Catalyst.Hooks.runtime_ready?()
    assert BootGuard.crashed_last_boot?()
  end

  defp write_probe(extensions_dir) do
    File.write!(
      Path.join(extensions_dir, "bootstrap_probe.ex"),
      ~S"""
      defmodule Catalyst.Ext.BootstrapProbePage do
        def render(assigns), do: assigns
      end

      defmodule Catalyst.Ext.BootstrapProbeExtension do
        use Catalyst.Extension

        @impl true
        def setup(api) do
          case Application.get_env(:catalyst_web, :extensions_bootstrap_test_pid) do
            pid when is_pid(pid) -> send(pid, {:bootstrap_probe_setup, self()})
            _missing -> :ok
          end

          Catalyst.ExtensionAPI.register_page(
            api,
            "bootstrap-probe",
            Catalyst.Ext.BootstrapProbePage
          )
        end
      end
      """
    )
  end

  defp restart_extensions! do
    runtime = extension_runtime_supervisor!()
    old = Process.whereis(Extensions)
    ref = Process.monitor(old)

    assert :ok = Supervisor.terminate_child(runtime, Extensions)
    assert_receive {:DOWN, ^ref, :process, ^old, _reason}
    assert {:ok, replacement} = Supervisor.restart_child(runtime, Extensions)
    replacement
  end

  defp extension_runtime_supervisor! do
    Catalyst.Supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Catalyst.ExtensionRuntimeSupervisor, pid, :supervisor, _modules} -> pid
      _child -> nil
    end)
    |> case do
      pid when is_pid(pid) -> pid
      nil -> flunk("extension runtime supervisor is not running")
    end
  end

  defp await_bootstrap_complete!(attempts \\ 200)

  defp await_bootstrap_complete!(0), do: flunk("extension bootstrap did not complete")

  defp await_bootstrap_complete!(attempts) do
    case :sys.get_state(Extensions) do
      %{bootstrap: :complete} ->
        :ok

      _in_progress ->
        receive do
        after
          10 -> await_bootstrap_complete!(attempts - 1)
        end
    end
  end

  defp start_lease!(id) do
    start_supervised!(%{
      id: id,
      start: {Agent, :start_link, [fn -> :ready end]},
      restart: :temporary
    })
  end

  defp register_live_web_leases do
    supervisor = Process.whereis(CatalystWeb.Supervisor)
    Extensions.register_host(:web, supervisor)
  end

  defp erase_web_leases do
    :persistent_term.erase({Extensions, :host_lease, :web})
  end

  defp host_lease, do: :persistent_term.get({Extensions, :host_lease, :web}, :missing)

  defp restore_lease(:missing), do: :persistent_term.erase({Extensions, :host_lease, :web})
  defp restore_lease(pid), do: :persistent_term.put({Extensions, :host_lease, :web}, pid)

  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
end
