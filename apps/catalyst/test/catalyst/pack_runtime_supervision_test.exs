defmodule Catalyst.PackRuntimeSupervisionTest do
  use ExUnit.Case, async: false

  test "a Computer helper restart preserves viewport ownership" do
    viewport = Process.whereis(Catalyst.Tools.Computer.Viewport)
    helper = Process.whereis(Catalyst.Tools.Computer.Helper)
    assert is_pid(viewport)
    assert is_pid(helper)
    ref = Process.monitor(helper)

    Process.exit(helper, :kill)
    assert_receive {:DOWN, ^ref, :process, ^helper, :killed}
    _state = :sys.get_state(Catalyst.Tools.Computer.RuntimeSupervisor)

    assert Process.whereis(Catalyst.Tools.Computer.Viewport) == viewport
    assert is_pid(Process.whereis(Catalyst.Tools.Computer.Helper))
    refute Process.whereis(Catalyst.Tools.Computer.Helper) == helper
  end
end
