defmodule Catalyst.ACP.ClientTest do
  use ExUnit.Case, async: false

  alias Catalyst.ACP.{Agent, Client}
  alias Catalyst.Session.Manager

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "catalyst_acp_client_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "a cancellation without a terminal response tears down the client", %{tmp: tmp} do
    log_path = Path.join(tmp, "cancel.json")

    {:ok, agent} =
      Agent.new(
        id: "cancel-fixture",
        name: "Cancel fixture",
        command: System.find_executable("elixir"),
        args: [fixture_path()],
        env: [
          {"ACP_FIXTURE_LOG", log_path},
          {"ACP_FIXTURE_PROMPT", "hang"}
        ]
      )

    {:ok, %{id: id}} = Manager.start_session(cwd: tmp)
    on_exit(fn -> Manager.stop(id) end)

    assert {:ok, client} =
             Catalyst.ACP.Supervisor.client(id, agent, tmp, cancel_timeout: 50)

    assert {:ok, ref} = Client.prompt(client, "wait")
    monitor = Process.monitor(client)
    assert :ok = Client.cancel(client, ref)

    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}, 1_000
    assert File.read!(log_path) =~ ~s("method":"session/cancel")
  end

  defp fixture_path do
    Path.expand("../../fixtures/acp_agent.exs", __DIR__)
  end
end
