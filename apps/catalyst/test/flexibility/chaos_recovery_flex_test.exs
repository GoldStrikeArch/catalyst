defmodule Catalyst.Flex.ChaosRecoveryFlexTest do
  use Catalyst.FlexCase, async: false

  @moduletag :flexibility

  import ExUnit.CaptureLog

  alias Catalyst.Extensions
  alias Catalyst.Extensions.BootGuard

  test "C6: compile failure is inert and a stale marker skips an unloaded probe", %{
    flex_home: home
  } do
    broken =
      write_extension!(
        "broken_flex",
        "defmodule Catalyst.Ext.BrokenFlex do\n  def broken, do: @@@\nend\n"
      )

    capture_log(fn ->
      assert {:ok, %{loaded: loaded, failed: [{^broken, _reason}]}} = Extensions.load_all()
      assert Enum.all?(loaded, &(&1.source == :bundled))
    end)

    assert Extensions.fetch("broken_flex") == :error
    refute Enum.any?(Extensions.list_loaded(), &(&1.owner == "broken_flex"))
    refute Code.ensure_loaded?(Catalyst.Ext.BrokenFlex)

    remove_extension!("broken_flex")
    assert {:ok, %{failed: []}} = Extensions.load_all()

    sentinel = Path.join(home, "safe_mode_setup_ran")
    previous_sentinel = with_app_env(:catalyst, :flex_safe_mode_sentinel, sentinel)
    probe = write_extension!("safe_mode_probe", Fixtures.extension_source!("safe_mode_probe"))

    BootGuard.mark_booting()
    old_pid = Process.whereis(Extensions)
    ref = Process.monitor(old_pid)

    capture_log(fn ->
      Process.exit(old_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}, 1_000

      new_pid = wait_for_restart!(Extensions, old_pid)
      _ = :sys.get_state(new_pid)

      assert Extensions.boot_status() == {:safe_mode, :crash_detected}
      assert {:ok, _module} = Extensions.fetch("read")
      refute File.exists?(sentinel)
      refute Code.ensure_loaded?(Catalyst.Ext.SafeModeProbe)

      File.rm!(probe)
      assert {:ok, %{failed: []}} = Extensions.load_all()
      assert Extensions.boot_status() == :ok
    end)

    restore_app_env(:catalyst, :flex_safe_mode_sentinel, previous_sentinel)
  end
end
