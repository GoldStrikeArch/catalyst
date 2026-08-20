defmodule Catalyst.Session.ProviderlessWorkflowTest do
  use ExUnit.Case, async: false

  alias Catalyst.Agent.Event
  alias Catalyst.Message
  alias Catalyst.Session.{Manager, Server}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "catalyst_providerless_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "a providerless workflow runs and persists without a model provider", %{tmp: tmp} do
    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(
        cwd: tmp,
        provider: nil,
        model: nil,
        tools: [],
        opts: [loop: Catalyst.Test.ProviderlessWorkflow, providerless_test_pid: self()]
      )

    on_exit(fn -> Manager.stop(id) end)
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    assert :ok = Server.prompt(pid, "hello")
    assert_receive {:providerless_config, nil}
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 1_000
    _ = :sys.get_state(pid)

    assert [
             %Message.User{},
             %Message.Assistant{api: "fixture", provider: "fixture"}
           ] = Server.state(pid).messages
  end
end
