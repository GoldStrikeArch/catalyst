defmodule Catalyst.Extensions.BootGuardTest do
  # async: false — the marker file and Extensions server are global.
  use ExUnit.Case, async: false

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

  test "a missing marker (first boot) is not a crash" do
    File.rm(BootGuard.marker_path())
    refute BootGuard.crashed_last_boot?()
  end

  test "a stale booting marker with no extension files boots normally and self-heals" do
    # The previous boot was quit inside the stabilization window (desktop quit
    # is a halt — nothing marks clean): with nothing to load, safe mode would
    # protect nothing, so boot proceeds and the marker self-heals.
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
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

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

  test "reload_after_wiring skips and preserves crash-detected safe mode" do
    on_exit(fn -> :persistent_term.put({Catalyst.Extensions, :boot_status}, :ok) end)

    # Simulate the state after a crash-detected boot: marker stale, status set.
    BootGuard.mark_booting()
    :persistent_term.put({Catalyst.Extensions, :boot_status}, {:safe_mode, :crash_detected})

    assert {:skipped, {:safe_mode, :crash_detected}} = Extensions.reload_after_wiring()

    # Nothing was loaded and nothing was cleared: a relaunch still detects it.
    assert BootGuard.crashed_last_boot?()
    assert Extensions.boot_status() == {:safe_mode, :crash_detected}
  end

  test "reload_after_wiring loads on a clean boot but never marks the boot OK" do
    on_exit(fn -> :persistent_term.put({Catalyst.Extensions, :boot_status}, :ok) end)
    :persistent_term.put({Catalyst.Extensions, :boot_status}, :ok)
    File.mkdir_p!(Extensions.dir())

    # Pretend we're inside the stabilization window: marker still "booting".
    BootGuard.mark_booting()

    assert {:ok, %{loaded: _, failed: _}} = Extensions.reload_after_wiring()

    # The marker is untouched — only the stabilization timer (or an explicit
    # load_all) may flip it to ok.
    assert BootGuard.crashed_last_boot?()
  end
end
