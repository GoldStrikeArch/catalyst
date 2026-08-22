defmodule Catalyst.RecoveryHostTest do
  use ExUnit.Case, async: true

  @host Path.expand("../../../../rel/recovery_host", __DIR__)
  @child Path.expand("../fixtures/recovery_host/fake_child.sh", __DIR__)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_recovery_host_#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    state = Path.join(home, "recovery")
    File.mkdir_p!(state)

    on_exit(fn -> File.rm_rf(root) end)
    %{home: home, state: state}
  end

  test "records a profile only after the child proves readiness", %{home: home, state: state} do
    assert {"", 0} = run_host(home, state, "ready")
    assert File.read!(Path.join(state, "last_known_good_profile")) == "coding-agent\n"
    assert File.read!(Path.join(state, "boot_status")) == "stopped:0:coding-agent:0\n"
    assert File.read!(Path.join(state, "safe_mode")) == "0\n"
    refute File.exists?(Path.join(state, "child_pid"))
  end

  test "rolls back a failed boot and retries once in safe mode", %{home: home, state: state} do
    File.write!(Path.join(home, "product_profile"), "ide\n")
    File.write!(Path.join(state, "last_known_good_profile"), "coding-agent\n")

    assert {"", 0} = run_host(home, state, "rollback", "coding-agent")
    assert File.read!(Path.join(home, "product_profile")) == "coding-agent\n"
    assert File.read!(Path.join(state, "last_known_good_profile")) == "coding-agent\n"
    assert File.read!(Path.join(state, "safe_mode")) == "1\n"
    assert File.read!(Path.join(state, "boot_status")) == "stopped:0:coding-agent:1\n"
    assert File.read!(Path.join(state, "count")) == "2\n"
  end

  test "uses the default profile when a failed boot has no last-known-good profile", %{
    home: home,
    state: state
  } do
    File.write!(Path.join(home, "product_profile"), "unknown-but-valid\n")

    assert {"", 0} = run_host(home, state, "rollback", "coding-agent")
    assert File.read!(Path.join(home, "product_profile")) == "coding-agent\n"
    assert File.read!(Path.join(state, "last_known_good_profile")) == "coding-agent\n"
    assert File.read!(Path.join(state, "safe_mode")) == "1\n"
    assert File.read!(Path.join(state, "boot_status")) == "stopped:0:coding-agent:1\n"
    assert File.read!(Path.join(state, "count")) == "2\n"
  end

  test "does not roll back a child that failed after proving readiness", %{
    home: home,
    state: state
  } do
    File.write!(Path.join(home, "product_profile"), "ide\n")
    File.write!(Path.join(state, "last_known_good_profile"), "coding-agent\n")

    assert {"", 5} = run_host(home, state, "ready_failure")
    assert File.read!(Path.join(home, "product_profile")) == "ide\n"
    assert File.read!(Path.join(state, "last_known_good_profile")) == "ide\n"
    assert File.read!(Path.join(state, "safe_mode")) == "0\n"
    assert File.read!(Path.join(state, "boot_status")) == "stopped:5:ide:0\n"
  end

  test "does not accept a fallback product as the requested profile", %{
    home: home,
    state: state
  } do
    File.write!(Path.join(home, "product_profile"), "ide\n")
    File.write!(Path.join(state, "last_known_good_profile"), "coding-agent\n")

    assert {"", 0} = run_host(home, state, "profile_mismatch")
    assert File.read!(Path.join(home, "product_profile")) == "coding-agent\n"
    assert File.read!(Path.join(state, "last_known_good_profile")) == "coding-agent\n"
    assert File.read!(Path.join(state, "safe_mode")) == "1\n"
    assert File.read!(Path.join(state, "count")) == "2\n"
  end

  test "rejects an unbounded profile pointer before starting a child", %{
    home: home,
    state: state
  } do
    File.write!(Path.join(home, "product_profile"), String.duplicate("x", 1_025))

    assert {output, 64} = run_host(home, state, "ready")
    assert output =~ "invalid profile pointer"
    refute File.exists?(Path.join(state, "child_pid"))
  end

  test "diagnostics expose the bounded recovery state", %{home: home, state: state} do
    assert {"", 0} = run_host(home, state, "ready")

    assert {output, 0} =
             System.cmd(@host, ["diagnostics", "--state-dir", state],
               env: [{"CATALYST_HOME", home}],
               stderr_to_stdout: true
             )

    assert output =~ "profile=coding-agent\n"
    assert output =~ "last_known_good=coding-agent\n"
    assert output =~ "status=stopped:0:coding-agent:0\n"
  end

  defp run_host(home, state, scenario, expected_profile \\ "coding-agent") do
    System.cmd(
      @host,
      ["start", "--state-dir", state, "--deadline", "2", "--", @child],
      env: [
        {"CATALYST_HOME", home},
        {"TEST_RECOVERY_SCENARIO", scenario},
        {"TEST_RECOVERY_STATE", state},
        {"EXPECTED_PROFILE", expected_profile}
      ],
      stderr_to_stdout: true
    )
  end
end
