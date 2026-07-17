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
end
