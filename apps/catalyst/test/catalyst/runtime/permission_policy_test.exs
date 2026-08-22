defmodule Catalyst.Runtime.PermissionPolicyTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.Agent.ToolRunner
  alias Catalyst.Content
  alias Catalyst.Contracts.PermissionPolicy.V1
  alias Catalyst.ExtensionAPI
  alias Catalyst.Runtime.{ExtensionPoints, PermissionPolicy}

  defmodule DenyPolicy do
    @behaviour Catalyst.Contracts.PermissionPolicy.V1

    @impl true
    def authorize(action, principal, resource, context) do
      send(:persistent_term.get({__MODULE__, :test}), {
        :permission_request,
        action,
        principal,
        resource,
        context
      })

      {:deny, "tool denied by policy"}
    end
  end

  defmodule HangingPolicy do
    @behaviour Catalyst.Contracts.PermissionPolicy.V1

    @impl true
    def authorize(_action, _principal, _resource, _context) do
      receive do
        :never -> :allow
      end
    end
  end

  defmodule ProbeTool do
    use Catalyst.Tools.Tool

    @impl true
    def name, do: "permission_probe"

    @impl true
    def description, do: "reports whether permission gating was bypassed"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _context) do
      send(:persistent_term.get({__MODULE__, :test}), :probe_executed)
      result("executed")
    end
  end

  setup do
    owner = "permission_policy_test_#{System.unique_integer([:positive])}"
    :persistent_term.put({DenyPolicy, :test}, self())
    :persistent_term.put({ProbeTool, :test}, self())

    on_exit(fn ->
      ExtensionPoints.purge_owner(owner)
      :persistent_term.erase({DenyPolicy, :test})
      :persistent_term.erase({ProbeTool, :test})
    end)

    {:ok, owner: owner}
  end

  test "the built-in policy preserves trusted local execution" do
    assert PermissionPolicy.explain().selected.implementation == Catalyst.Permissions.AllowAll

    assert :allow =
             PermissionPolicy.authorize(
               %{type: :tool_call},
               %{type: :agent, session_id: "session"},
               %{type: :tool},
               %{cwd: "."}
             )
  end

  test "ToolRunner enforces a claimed policy before executing the tool", %{owner: owner} do
    claim(owner, DenyPolicy)

    calls = [%{id: "call-1", name: "permission_probe", arguments: %{}}]
    config = %{cwd: ".", tools: [ProbeTool], opts: [session_id: "session-1"]}
    {[result], false} = ToolRunner.run_batch(calls, config, fn _event -> :ok end)

    assert result.is_error
    assert result.details.blocked
    assert Content.text_of(result.content) == "tool denied by policy"
    refute_receive :probe_executed

    assert_receive {:permission_request, action, principal, resource, %{cwd: "."}}
    assert action.name == "permission_probe"
    assert principal.session_id == "session-1"
    assert resource == %{type: :tool, name: "permission_probe"}
  end

  test "a hanging policy fails closed at the configured deadline", %{owner: owner} do
    previous_timeout = Application.fetch_env(:catalyst, :permission_policy_timeout)
    Application.put_env(:catalyst, :permission_policy_timeout, 10)

    on_exit(fn -> restore_env(:permission_policy_timeout, previous_timeout) end)
    claim(owner, HangingPolicy)

    assert {:deny, :permission_policy_timeout} =
             PermissionPolicy.authorize(
               %{type: :tool_call},
               %{type: :agent, session_id: "session"},
               %{type: :tool},
               %{cwd: "."}
             )
  end

  defp claim(owner, implementation) do
    assert :ok =
             owner
             |> ExtensionAPI.new()
             |> ExtensionAPI.claim(PermissionPolicy.key(), implementation,
               contract: V1.ref(),
               priority: 900
             )
  end
end
