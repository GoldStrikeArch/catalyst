defmodule Catalyst.Extensions.BootGuardTest do
  # async: false — the marker file and Extensions server are global.
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2, wait_until: 1]

  import ExUnit.CaptureLog

  alias Catalyst.Extensions
  alias Catalyst.Extensions.BootGuard

  setup do
    # Leave the world clean: tests below flip the marker around.
    on_exit(fn -> BootGuard.mark_ok() end)
    :ok
  end

  test "marker lifecycle: booting reads as a crash, ok reads as clean" do
    BootGuard.mark_ok()
    refute BootGuard.crashed_last_boot?()

    BootGuard.mark_booting()
    assert BootGuard.crashed_last_boot?()

    BootGuard.mark_ok()
    refute BootGuard.crashed_last_boot?()
  end

  test "a stale stabilization timer cannot bless a newly armed boot" do
    old_token = BootGuard.arm()
    BootGuard.mark_booting()

    assert :ok = BootGuard.mark_ok(old_token)
    assert BootGuard.crashed_last_boot?()

    current_token = BootGuard.arm()
    assert :ok = BootGuard.mark_ok(current_token)
    refute BootGuard.crashed_last_boot?()
  end

  test "a non-clean boot status remains authoritative across a server generation change" do
    status_key = {Extensions, :boot_status}
    owner_key = {Extensions, :boot_status_owner}
    previous_status = :persistent_term.get(status_key, :missing)
    previous_owner = :persistent_term.get(owner_key, :missing)

    on_exit(fn ->
      restore_persistent_term(status_key, previous_status)
      restore_persistent_term(owner_key, previous_owner)
    end)

    :persistent_term.put(status_key, {:safe_mode, :crash_detected})
    :persistent_term.put(owner_key, self())

    refute Process.whereis(Extensions) == self()
    assert Extensions.boot_status() == {:safe_mode, :crash_detected}
  end

  test "a stale boot result cannot overwrite a newer explicit load" do
    assert {:ok, %{failed: []}} = Extensions.load_all()
    assert Extensions.boot_status() == :ok

    # Boot outcomes are recorded by the boot task itself, under the load lock
    # and gated on its generation — the result message delivered to the server
    # only schedules the stabilization timer. A failure result that lost the
    # race to a newer explicit load must not regress the published status.
    :ok = Extensions.inject_boot_result({:error, :stale_boot_failure})
    _ = :sys.get_state(Extensions)

    assert Extensions.boot_status() == :ok
    refute BootGuard.crashed_last_boot?()
  end

  test "bootstrap/0 acknowledges without rerunning extension loads" do
    # Quiesce first: a previous test's server restart can leave its boot load
    # still queued on the load lock, and it must settle before the probe file
    # exists (its setup notification would be mistaken for a bootstrap rerun).
    File.mkdir_p!(Extensions.dir())
    assert {:ok, _result} = Extensions.load_all()

    path = Path.join(Extensions.dir(), "boot_revision_probe.ex")
    previous_probe = Application.fetch_env(:catalyst, :boot_revision_probe_pid)
    Application.put_env(:catalyst, :boot_revision_probe_pid, self())

    File.write!(path, ~S"""
    defmodule Catalyst.Ext.BootRevisionProbe do
      use Catalyst.Extension

      @impl true
      def setup(_api) do
        case Application.get_env(:catalyst, :boot_revision_probe_pid) do
          pid when is_pid(pid) ->
            send(pid, {:boot_revision_setup, self()})

            receive do
              :continue -> :ok
            after
              2_000 -> :ok
            end

          _missing ->
            :ok
        end
      end
    end
    """)

    on_exit(fn ->
      File.rm(path)
      restore_env(:boot_revision_probe_pid, previous_probe)
      _ = Extensions.load_all()
    end)

    explicit =
      Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
        Extensions.load_all()
      end)

    assert_receive {:boot_revision_setup, setup}
    send(setup, :continue)
    assert {:ok, %{failed: []}} = Task.await(explicit, 5_000)
    drain_stray_setups()

    # The explicit success completes a pending bootstrap generation. A later
    # host acknowledgement is therefore idempotent and cannot queue setup a
    # second time; explicit reruns continue to go through load_all/0.
    assert :ok = Extensions.bootstrap()
    _ = :sys.get_state(Extensions)
    refute_receive {:boot_revision_setup, _second_setup}, 200
    assert Extensions.boot_status() == :ok
  end

  test "a core-only runtime starts bootstrap immediately" do
    case Application.spec(:catalyst_web, :vsn) do
      nil ->
        BootGuard.mark_ok()
        restart_extensions()

        state = :sys.get_state(Extensions)
        assert state.bootstrap in [:running, :complete]
        assert :ok = Extensions.await_ready()
        wait_until(fn -> match?(%{bootstrap: :complete}, :sys.get_state(Extensions)) end)
        assert Catalyst.Hooks.runtime_ready?()

      _web_capable_umbrella_context ->
        # The umbrella test runner intentionally loads the web application
        # specification; the core-only branch is exercised by this app's own
        # test task and by the CLI release.
        assert Extensions.host_ready?(:web)
        assert :ok = Extensions.await_ready()
    end
  end

  test "await_ready requires a responsive current coordinator" do
    pid = Process.whereis(Extensions)
    :ok = :sys.suspend(pid)

    try do
      assert {:error, :timeout} = Extensions.await_ready(20)
    after
      :ok = :sys.resume(pid)
    end

    assert :ok = Extensions.await_ready()
  end

  # Release any setup notifications from loads that were already in flight
  # before bootstrap/0 is probed (unrelated to what this test asserts).
  defp drain_stray_setups do
    receive do
      {:boot_revision_setup, stray} ->
        send(stray, :continue)
        drain_stray_setups()
    after
      300 -> :ok
    end
  end

  test "a compiler from a dead generation cannot leave code live in safe mode" do
    # A prior test may have restarted the server and left its supervised boot
    # workflow queued on the load lock. Settle that generation before adding a
    # source whose top-level compiler intentionally blocks.
    wait_until(fn -> match?(%{bootstrap: :complete}, :sys.get_state(Extensions)) end)

    File.mkdir_p!(Extensions.dir())
    path = Path.join(Extensions.dir(), "stale_compile_probe.ex")
    token = make_ref()
    previous_probe = Application.fetch_env(:catalyst, :stale_compile_probe)
    previous_safe_mode = Application.fetch_env(:catalyst, :safe_mode)
    Application.put_env(:catalyst, :stale_compile_probe, {self(), token})
    Application.put_env(:catalyst, :safe_mode, false)

    File.write!(path, ~S"""
    {test, token} = Application.fetch_env!(:catalyst, :stale_compile_probe)
    send(test, {:compile_paused, self(), token})

    receive do
      {:continue_compile, ^token} -> :ok
    end

    defmodule Catalyst.Ext.StaleCompileProbe do
      def loaded?, do: true
    end
    """)

    on_exit(fn ->
      File.rm(path)
      restore_env(:stale_compile_probe, previous_probe)
      restore_env(:safe_mode, previous_safe_mode)
      _ = Extensions.load_all()
    end)

    refute Code.ensure_loaded?(Catalyst.Ext.StaleCompileProbe)

    load =
      Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
        Extensions.load_file(path)
      end)

    assert_receive {:compile_paused, compiler, ^token}
    Application.put_env(:catalyst, :safe_mode, true)

    extensions = Process.whereis(Extensions)
    ref = Process.monitor(extensions)
    Process.exit(extensions, :kill)
    assert_receive {:DOWN, ^ref, :process, ^extensions, :killed}

    # The replacement boots immediately in safe mode; the in-flight load
    # transaction keeps the load lock but the replacement never needs it.
    replacement = wait_for_replacement!(extensions)

    send(compiler, {:continue_compile, token})
    # Generous deadline: the resumed compile still runs a full bounded-task
    # pipeline plus the replacement's init before the rejection surfaces.
    assert {:error, :stale_extension_generation} = Task.await(load, 15_000)
    wait_until(fn -> match?(%{bootstrap: :complete}, :sys.get_state(replacement, 5_000)) end)
    assert Extensions.boot_status() == {:safe_mode, :env}
    refute Code.ensure_loaded?(Catalyst.Ext.StaleCompileProbe)
  end

  test "safe-mode restart drains modules from a killed boot compiler" do
    File.mkdir_p!(Extensions.dir())
    path = Path.join(Extensions.dir(), "boot_compile_leak_probe.ex")
    token = make_ref()
    previous_probe = Application.fetch_env(:catalyst, :boot_compile_leak_probe)
    previous_safe_mode = Application.fetch_env(:catalyst, :safe_mode)
    Application.put_env(:catalyst, :boot_compile_leak_probe, {self(), token})
    Application.put_env(:catalyst, :safe_mode, false)

    File.write!(path, ~S"""
    defmodule Catalyst.Ext.BootCompileLeakProbe do
      def loaded?, do: true
    end

    {test, token} = Application.fetch_env!(:catalyst, :boot_compile_leak_probe)
    send(test, {:boot_compile_paused, self(), token})

    receive do
      {:continue_boot_compile, ^token} -> :ok
    after
      2_000 -> :ok
    end
    """)

    on_exit(fn ->
      File.rm(path)
      restore_env(:boot_compile_leak_probe, previous_probe)
      restore_env(:safe_mode, previous_safe_mode)
      _ = Extensions.load_all()
    end)

    refute Code.ensure_loaded?(Catalyst.Ext.BootCompileLeakProbe)

    # Trigger a REAL boot load (a server restart) and pause its compiler
    # mid-file, with the probe module already defined in the VM.
    BootGuard.mark_ok()

    capture_log(fn ->
      restart_extensions()
      assert_receive {:boot_compile_paused, compiler, ^token}, 5_000
      assert Code.ensure_loaded?(Catalyst.Ext.BootCompileLeakProbe)
      compiler_ref = Process.monitor(compiler)

      Application.put_env(:catalyst, :safe_mode, true)
      extensions = Process.whereis(Extensions)
      ref = Process.monitor(extensions)
      Process.exit(extensions, :kill)
      assert_receive {:DOWN, ^ref, :process, ^extensions, :killed}

      replacement = wait_for_replacement!(extensions)
      send(compiler, {:continue_boot_compile, token})

      # The surviving boot compiler finishes, its work is rejected as a dead
      # generation, and the compiled module is drained from the VM without
      # disturbing the replacement's safe-mode status.
      assert_receive {:DOWN, ^compiler_ref, :process, ^compiler, _reason}, 5_000
      wait_until(fn -> match?(%{bootstrap: :complete}, :sys.get_state(replacement, 5_000)) end)
      assert Extensions.boot_status() == {:safe_mode, :env}
      wait_until(fn -> not Catalyst.Extensions.CompilerTracer.provisional?() end)
      wait_until(fn -> not Code.ensure_loaded?(Catalyst.Ext.BootCompileLeakProbe) end)
    end)
  end

  test "a missing marker (first boot) is not a crash" do
    File.rm(BootGuard.marker_path())
    refute BootGuard.crashed_last_boot?()
  end

  test "an unwritable marker logs a warning but remains best-effort" do
    blocker =
      Path.join(System.tmp_dir!(), "boot_marker_blocker_#{System.unique_integer([:positive])}")

    File.write!(blocker, "not a directory")
    previous = Application.get_env(:catalyst, :boot_marker_path)
    Application.put_env(:catalyst, :boot_marker_path, Path.join(blocker, "marker"))

    on_exit(fn ->
      File.rm(blocker)

      case previous do
        nil -> Application.delete_env(:catalyst, :boot_marker_path)
        path -> Application.put_env(:catalyst, :boot_marker_path, path)
      end
    end)

    log = capture_log(fn -> assert :ok = BootGuard.mark_booting() end)

    assert log =~ "could not write boot marker"
  end

  test "a stale booting marker with no extension files boots normally and self-heals" do
    # The previous boot was quit inside the stabilization window (desktop quit
    # is a halt — nothing marks clean): with nothing to load, safe mode would
    # protect nothing, so boot proceeds and the marker self-heals.
    assert {:ok, %{failed: []}} = Extensions.load_all()
    File.rm_rf!(Extensions.dir())
    BootGuard.mark_booting()

    capture_log(fn ->
      restart_extensions()

      assert Extensions.boot_status() == :ok
      # Marker re-arms and flips to ok after the boot load + stabilization
      # window (50ms in test env).
      wait_until(fn -> not BootGuard.crashed_last_boot?() end)
    end)
  end

  test "a stale booting marker with extension files present engages safe mode" do
    File.mkdir_p!(Extensions.dir())
    path = Path.join(Extensions.dir(), "guard_present.ex")

    File.write!(path, """
    defmodule Catalyst.Ext.GuardPresent do
      def name, do: "guard_present"
      def description, do: "boot guard probe"
      def parameters, do: %{"type" => "object", "properties" => %{}}
      def execute(_args, _ctx), do: %{content: "ok"}
    end
    """)

    on_exit(fn -> File.rm_rf!(Extensions.dir()) end)
    BootGuard.mark_booting()

    capture_log(fn ->
      restart_extensions()

      # The extension is skipped, the status reports it, and the marker stays
      # stale so a relaunch is still safe.
      assert Extensions.boot_status() == {:safe_mode, :crash_detected}
      assert Extensions.fetch("guard_present") == :error
      assert BootGuard.crashed_last_boot?()

      # Documented recovery: remove/fix the files and run an explicit load.
      File.rm_rf!(path)
      assert {:ok, %{failed: []}} = Extensions.load_all()
      assert Extensions.boot_status() == :ok
      refute BootGuard.crashed_last_boot?()
    end)
  end

  test "a boot owner collision is surfaced and never marks the boot clean" do
    File.mkdir_p!(Extensions.dir())
    first = Path.join(Extensions.dir(), "Boot Owner.ex")
    second = Path.join(Extensions.dir(), "boot---owner.ex")
    File.write!(first, "defmodule Catalyst.Ext.BootOwnerA do end")
    File.write!(second, "defmodule Catalyst.Ext.BootOwnerB do end")

    on_exit(fn ->
      File.rm(first)
      File.rm(second)
      _ = Extensions.load_all()
    end)

    BootGuard.mark_ok()

    log =
      capture_log(fn ->
        restart_extensions()
        wait_until(fn -> match?({:load_failed, _reason}, Extensions.boot_status()) end)
        _ = :sys.get_state(Extensions)
        Logger.flush()
      end)

    assert {:load_failed, {:owner_collision, "boot_owner", paths}} = Extensions.boot_status()
    assert Enum.sort(paths) == Enum.sort([first, second])
    assert BootGuard.crashed_last_boot?()
    assert log =~ "boot load failed"
    refute Code.ensure_loaded?(Catalyst.Ext.BootOwnerA)
    refute Code.ensure_loaded?(Catalyst.Ext.BootOwnerB)
  end

  test "the published guide follows an explicit Catalyst home" do
    root =
      Path.join(System.tmp_dir!(), "catalyst_guide_home_#{System.unique_integer([:positive])}")

    home = Path.join(root, "home")
    extensions = Path.join([root, "elsewhere", "extensions"])
    old_home = Application.fetch_env(:catalyst, :home)
    old_extensions = Application.fetch_env(:catalyst, :extensions_dir)
    old_safe_mode = Application.fetch_env(:catalyst, :safe_mode)

    Application.put_env(:catalyst, :home, home)
    Application.put_env(:catalyst, :extensions_dir, extensions)
    Application.put_env(:catalyst, :safe_mode, true)
    File.mkdir_p!(extensions)
    BootGuard.mark_ok()

    on_exit(fn ->
      restore_env(:home, old_home)
      restore_env(:extensions_dir, old_extensions)
      restore_env(:safe_mode, old_safe_mode)
      BootGuard.mark_ok()
      restart_extensions()
      File.rm_rf(root)
    end)

    restart_extensions()
    wait_until(fn -> File.regular?(Path.join(home, "guide.md")) end)
    assert File.regular?(Path.join(home, "guide.md"))
    refute File.exists?(Path.join(Path.dirname(extensions), "guide.md"))
  end

  defp restart_extensions do
    pid = Process.whereis(Extensions)
    assert pid, "expected Catalyst.Extensions to be running"
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    wait_until(fn ->
      case Process.whereis(Extensions) do
        nil -> false
        ^pid -> false
        _new -> true
      end
    end)

    # The name registers before init/1 runs; sync so callers observe the new
    # boot's published status, not the previous generation's.
    _ = :sys.get_state(Process.whereis(Extensions))
    :ok
  end

  defp wait_for_replacement!(old_pid) do
    wait_until(fn ->
      case Process.whereis(Extensions) do
        pid when is_pid(pid) and pid != old_pid -> true
        _missing_or_old -> false
      end
    end)

    Process.whereis(Extensions)
  end

  defp restore_persistent_term(key, :missing), do: :persistent_term.erase(key)
  defp restore_persistent_term(key, value), do: :persistent_term.put(key, value)

  test "a successful explicit load_all clears crash-detected safe mode" do
    BootGuard.mark_booting()
    assert BootGuard.crashed_last_boot?()

    File.mkdir_p!(Extensions.dir())
    assert {:ok, %{loaded: _, failed: []}} = Extensions.load_all()

    refute BootGuard.crashed_last_boot?()
    assert Extensions.boot_status() == :ok
  end

  test "a load_all with failures does NOT clear crash-detected safe mode" do
    BootGuard.mark_booting()
    assert BootGuard.crashed_last_boot?()

    File.mkdir_p!(Extensions.dir())
    broken = Path.join(Extensions.dir(), "guard_broken.ex")
    File.write!(broken, "defmodule Catalyst.Ext.GuardBroken do @@@ end")
    on_exit(fn -> File.rm_rf!(Extensions.dir()) end)

    capture_log(fn ->
      assert {:ok, %{failed: [{^broken, _reason}]}} = Extensions.load_all()
    end)

    # The broken extension is still in place — a relaunch must stay safe.
    assert BootGuard.crashed_last_boot?()
  end
end
