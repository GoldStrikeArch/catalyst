defmodule Catalyst.Tools.RuntimeGraphTest do
  use ExUnit.Case, async: false

  alias Catalyst.Content
  alias Catalyst.Runtime.ReadModel
  alias Catalyst.Tools.RuntimeGraph

  setup do
    :ok =
      ReadModel.register_source(
        :core,
        {Catalyst.Runtime.Sources.Core, :snapshot}
      )

    :ok
  end

  test "lists the observable graph with bounded structured details" do
    result = RuntimeGraph.execute(%{}, context())
    assert [%Content.Text{text: text}] = result.content
    assert text =~ "agent.run_engine/default"
    assert text =~ "agent.tool/\"runtime_graph\""
    assert text =~ "Generations:"
    assert text =~ "Leases:"
    assert text =~ "Artifacts:"
    assert result.details.claim_count > 0
    assert result.details.contribution_count > 0
    assert is_integer(result.details.generation_count)
    assert is_integer(result.details.lease_count)
    assert is_integer(result.details.artifact_count)
    assert byte_size(result.details.snapshot_id) == 64
  end

  test "explains one service and accepts human-friendly atom owner filters" do
    explained =
      RuntimeGraph.execute(
        %{"service" => "agent.run_engine/default"},
        context()
      )

    assert [%Content.Text{text: explanation}] = explained.content
    assert explanation =~ "Resolution: :resolved"
    assert explanation =~ "Catalyst.Agent.Loop"

    filtered = RuntimeGraph.execute(%{"owner" => "builtin"}, context())
    assert [%Content.Text{text: owner_view}] = filtered.content
    assert owner_view =~ "owner=:builtin"

    combined =
      RuntimeGraph.execute(
        %{"service" => "agent.run_engine/default", "owner" => "missing-owner"},
        context()
      )

    assert [%Content.Text{text: combined_view}] = combined.content
    assert combined_view =~ "Resolution: {:error, :no_matching_claim}"
    refute combined_view =~ "Catalyst.Agent.Loop"
  end

  test "invalid service keys raise a bounded tool error" do
    assert_raise ArgumentError, ~r/runtime graph query failed/, fn ->
      RuntimeGraph.execute(%{"service" => "not-a-service-key"}, context())
    end
  end

  test "reports unavailable lease introspection without crashing" do
    server = Process.whereis(Catalyst.Runtime.Leases)
    assert Process.unregister(Catalyst.Runtime.Leases)

    try do
      result = RuntimeGraph.execute(%{}, context())
      assert [%Content.Text{text: text}] = result.content
      assert text =~ "Leases:\n  unavailable:"
      assert result.details.lease_count == :unknown
    after
      assert Process.register(server, Catalyst.Runtime.Leases)
    end
  end

  defp context do
    %{
      cwd: File.cwd!(),
      session_id: "runtime-graph-tool-test",
      call_id: "call-1",
      report: fn _result -> :ok end
    }
  end
end
