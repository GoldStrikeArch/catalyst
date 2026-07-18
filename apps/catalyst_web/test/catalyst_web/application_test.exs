defmodule CatalystWeb.ApplicationTest do
  use ExUnit.Case, async: true

  alias CatalystWeb.Application

  test "post-start wiring runs only after a successful supervisor start" do
    test_pid = self()

    assert {:ok, test_pid} ==
             Application.complete_start({:ok, test_pid}, fn supervisor ->
               send(test_pid, {:after_start, supervisor})
             end)

    assert_receive {:after_start, ^test_pid}
  end

  test "a supervisor start error skips post-start wiring" do
    test_pid = self()
    error = {:error, {:shutdown, :endpoint_failed}}

    assert ^error =
             Application.complete_start(error, fn _supervisor ->
               send(test_pid, :unexpected_after_start)
             end)

    refute_receive :unexpected_after_start
  end
end
