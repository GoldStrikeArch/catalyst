defmodule Catalyst.ClaudeCode.LiveWireTest do
  @moduledoc """
  Opt-in live smoke test for the user-installed official Claude Code executable.

  Run only this test with:

      CATALYST_CLAUDE_LIVE=1 mix test --only live_wire \
        apps/catalyst/test/catalyst/claude_code/live_wire_test.exs

  The test makes two real subscription-backed requests and refuses to run unless
  `claude auth status --json` reports first-party Claude subscription routing.
  """

  use ExUnit.Case, async: false

  alias Catalyst.Agent.Event
  alias Catalyst.Content
  alias Catalyst.Message
  alias Catalyst.Session.{Manager, Server}

  @moduletag :live_wire

  case System.get_env("CATALYST_CLAUDE_LIVE") do
    "1" -> :ok
    _disabled -> @moduletag skip: "set CATALYST_CLAUDE_LIVE=1 to make real Claude requests"
  end

  case System.find_executable("claude") do
    nil -> @moduletag skip: "the official claude executable is not on PATH"
    _path -> :ok
  end

  test "two print-mode prompts continue the same Claude session" do
    assert :ok = subscription_route()

    tmp =
      Path.join(
        System.tmp_dir!(),
        "catalyst_claude_live_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
    end)

    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(
        cwd: tmp,
        provider: nil,
        model: nil,
        tools: [],
        opts: [
          loop: Catalyst.ClaudeCode.Workflow,
          claude_model: "sonnet",
          claude_tools: [],
          claude_timeout: 120_000
        ]
      )

    on_exit(fn -> Manager.stop(id) end)
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    assert :ok = Server.prompt(pid, "Reply with exactly CATALYST_CLAUDE_LIVE_ONE.")
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 120_000
    _ = :sys.get_state(pid)

    first = List.last(Server.state(pid).messages)
    assert %Message.Assistant{response_id: response_id} = first
    assert is_binary(response_id) and response_id != ""
    assert Content.text_of(first.content) =~ "CATALYST_CLAUDE_LIVE_ONE"

    assert :ok = Server.prompt(pid, "Reply with exactly CATALYST_CLAUDE_LIVE_TWO.")
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 120_000
    _ = :sys.get_state(pid)

    second = List.last(Server.state(pid).messages)
    assert %Message.Assistant{response_id: ^response_id} = second
    assert Content.text_of(second.content) =~ "CATALYST_CLAUDE_LIVE_TWO"
  end

  defp subscription_route do
    executable = System.find_executable("claude")

    case System.cmd(executable, ["auth", "status", "--json"], stderr_to_stdout: true) do
      {json, 0} ->
        validate_subscription_route(Jason.decode(json))

      {_output, _status} ->
        {:error, :claude_auth_status_failed}
    end
  end

  defp validate_subscription_route(
         {:ok,
          %{
            "loggedIn" => true,
            "authMethod" => "claude.ai",
            "apiProvider" => "firstParty"
          }}
       ),
       do: :ok

  defp validate_subscription_route(_status), do: {:error, :subscription_route_required}
end
