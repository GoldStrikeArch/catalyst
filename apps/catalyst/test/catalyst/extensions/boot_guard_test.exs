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
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:catalyst, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:catalyst, key)

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
