defmodule Catalyst.Tools.ContextTest do
  use ExUnit.Case, async: true

  alias Catalyst.Tools.Context

  test "builds the explicit inheritance context and keeps the session-id Access alias" do
    reporter = fn _result -> :ok end

    context =
      Context.new(
        cwd: "/tmp/project",
        session_id: "parent",
        model: :model,
        provider: :provider,
        opts: [reasoning_effort: "high"],
        workflow: {:default, ExampleWorkflow},
        tool_source: :extensions,
        agent_depth: 1,
        call_id: "call-1",
        report: reporter
      )

    assert context.parent_session_id == "parent"
    assert context.root_session_id == "parent"
    assert context.session_id == "parent"
    assert context[:session_id] == "parent"
    assert Map.get(context, :session_id) == "parent"
    assert context[:tool_source] == :extensions
    assert context.agent_depth == 1

    updated = put_in(context[:session_id], "new-parent")
    assert updated.parent_session_id == "new-parent"
    assert updated.session_id == "new-parent"
    assert Map.get(updated, :session_id) == "new-parent"
  end

  test "explicit roots win over the parent default" do
    context =
      Context.new(
        cwd: ".",
        parent_session_id: "parent",
        root_session_id: "root",
        call_id: "call",
        report: fn _ -> :ok end
      )

    assert context.root_session_id == "root"
  end
end
