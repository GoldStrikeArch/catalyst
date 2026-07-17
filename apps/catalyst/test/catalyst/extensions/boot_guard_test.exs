defmodule Catalyst.Extensions.BootGuardTest do
  # async: false — the marker file and Extensions server are global.
  use ExUnit.Case, async: false

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

  test "a successful explicit load_all clears crash-detected safe mode" do
    BootGuard.mark_booting()
    assert BootGuard.crashed_last_boot?()

    File.mkdir_p!(Extensions.dir())
    assert {:ok, _summaries} = Extensions.load_all()

    refute BootGuard.crashed_last_boot?()
    assert Extensions.boot_status() == :ok
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

    assert {:ok, _summaries} = Extensions.reload_after_wiring()

    # The marker is untouched — only the stabilization timer (or an explicit
    # load_all) may flip it to ok.
    assert BootGuard.crashed_last_boot?()
  end
end
