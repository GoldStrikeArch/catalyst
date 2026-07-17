defmodule Catalyst.Tools.ExecTest do
  use ExUnit.Case, async: true

  alias Catalyst.Tools.Exec

  defp sh, do: System.find_executable("sh")

  test "collect returns out and status without a :truncated key" do
    assert {:ok, %{out: out, status: 0} = res} = Exec.collect(sh(), ["-c", "echo hi"])
    assert out =~ "hi"
    refute Map.has_key?(res, :truncated)
  end

  test "collect timeout kills the child and drains port messages from the mailbox" do
    assert {:error, :timeout} =
             Exec.collect(sh(), ["-c", "while true; do echo spam; done"], timeout: 100)

    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "collect caps accumulated output at :max_output_bytes" do
    assert {:ok, %{out: out, status: 0, truncated: true}} =
             Exec.collect(sh(), ["-c", "while true; do echo spam; done"],
               max_output_bytes: 10_000,
               timeout: 10_000
             )

    assert byte_size(out) > 10_000
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "bash runs under real bash so bashisms work" do
    assert {:ok, %{out: out, status: 0}} = Exec.bash("[[ -n yes ]] && echo BASHISM_OK")
    assert out =~ "BASHISM_OK"
  end

  test "bash caps runaway output instead of buffering it until the timeout" do
    assert {:ok, %{out: out, status: 0, truncated: true}} =
             Exec.bash("while true; do echo spam; done",
               max_output_bytes: 10_000,
               timeout: 10_000
             )

    # Bounded: the cap plus at most one in-flight muontrap window (10KB).
    assert byte_size(out) > 10_000
    assert byte_size(out) < 100_000
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "bash timeout kills the spawned command and keeps partial output" do
    pidfile =
      Path.join(System.tmp_dir!(), "catalyst_exec_kill_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(pidfile) end)

    assert {:error, {:timeout, partial}} =
             Exec.bash("echo $$ > #{pidfile}; echo started; sleep 300", timeout: 300)

    assert partial =~ "started"
    assert {:messages, []} = Process.info(self(), :messages)

    # Closing the wrapper's port makes muontrap SIGTERM (then SIGKILL after
    # ~500ms) its child — poll until the recorded pid is gone.
    pid = pidfile |> File.read!() |> String.trim()
    assert wait_until_dead(pid)
  end

  defp wait_until_dead(pid, tries \\ 50) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} when tries > 0 ->
        Process.sleep(100)
        wait_until_dead(pid, tries - 1)

      {_, 0} ->
        false

      _ ->
        true
    end
  end
end
