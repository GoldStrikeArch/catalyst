defmodule Catalyst.ACP.LiveWireTest do
  @moduledoc """
  Opt-in live smoke test for an externally installed `claude-agent-acp`.

  Run only this test with:

      CATALYST_CLAUDE_ACP_LIVE=1 mix test --only live_wire \
        apps/catalyst/test/catalyst/acp/live_wire_test.exs
  """

  use ExUnit.Case, async: false

  alias Catalyst.Agent.Event
  alias Catalyst.Content
  alias Catalyst.Message
  alias Catalyst.Session.{Manager, Server}

  @moduletag :live_wire

  case System.get_env("CATALYST_CLAUDE_ACP_LIVE") do
    "1" ->
      :ok

    _disabled ->
      @moduletag skip: "set CATALYST_CLAUDE_ACP_LIVE=1 to make real Claude ACP requests"
  end

  case System.find_executable("claude-agent-acp") do
    nil -> @moduletag skip: "claude-agent-acp is not on PATH"
    _path -> :ok
  end

  case System.find_executable("claude") do
    nil -> @moduletag skip: "the official claude executable is required for auth preflight"
    _path -> :ok
  end

  test "two prompts reuse the live Claude ACP session" do
    assert :ok = subscription_route()

    tmp =
      Path.join(
        System.tmp_dir!(),
        "catalyst_claude_acp_live_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(
        cwd: tmp,
        provider: nil,
        model: nil,
        tools: [],
        opts: [
          loop: Catalyst.ACP.Workflow,
          acp_agent: %{
            id: "claude-live",
            name: "Claude ACP live",
            command: "claude-agent-acp",
            adapter: "claude"
          },
          acp_prompt_timeout: 120_000
        ]
      )

    on_exit(fn -> Manager.stop(id) end)
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    assert :ok = Server.prompt(pid, "Reply with exactly CATALYST_ACP_LIVE_ONE.")
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 120_000
    _ = :sys.get_state(pid)

    first = List.last(Server.state(pid).messages)
    assert %Message.Assistant{response_id: response_id} = first
    assert is_binary(response_id) and response_id != ""
    assert Content.text_of(first.content) =~ "CATALYST_ACP_LIVE_ONE"

    assert :ok = Server.prompt(pid, "Reply with exactly CATALYST_ACP_LIVE_TWO.")
    assert_receive {:agent_event, ^id, %Event.AgentEnd{}}, 120_000
    _ = :sys.get_state(pid)

    second = List.last(Server.state(pid).messages)
    assert %Message.Assistant{response_id: ^response_id} = second
    assert Content.text_of(second.content) =~ "CATALYST_ACP_LIVE_TWO"
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
