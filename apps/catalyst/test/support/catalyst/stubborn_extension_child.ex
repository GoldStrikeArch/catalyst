defmodule Catalyst.Test.StubbornExtensionChild do
  @moduledoc false

  # Simulates a wedged extension process: traps exits and ignores every
  # message, so only an untrappable direct kill can take it down. This is a raw
  # receive loop deliberately: gen_server intercepts a parent supervisor's
  # EXIT and complies with the shutdown.
  def start_link(test_pid) do
    pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)
        send(test_pid, {:stubborn, self()})
        loop()
      end)

    {:ok, pid}
  end

  defp loop do
    receive do
      _message -> loop()
    end
  end
end
