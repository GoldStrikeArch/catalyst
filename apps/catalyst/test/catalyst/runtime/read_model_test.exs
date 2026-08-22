defmodule Catalyst.Runtime.ReadModelTest do
  use ExUnit.Case, async: false

  alias Catalyst.LLM.Registry, as: ProviderRegistry
  alias Catalyst.Runtime
  alias Catalyst.Runtime.{ReadModel, ServiceKey}

  setup do
    # This module verifies the product baseline, not a prior test's runtime
    # provider overlay. Unregistering restores the compiled/configured seed and
    # clears any owner index entry atomically.
    :ok = ProviderRegistry.unregister_provider("openai-codex-responses")
    :ok = Catalyst.Extensions.await_ready()

    :ok =
      ReadModel.register_source(
        :core,
        {Catalyst.Runtime.Sources.Core, :snapshot}
      )

    on_exit(fn -> ReadModel.unregister_source(:broken_test_source) end)
    :ok
  end

  test "the aggregate graph contains core services and contributions" do
    graph = Runtime.snapshot(session_id: "runtime-read-model-test")
    repeated = Runtime.snapshot(session_id: "runtime-read-model-test")

    assert graph.source_status.core == :ready
    assert graph.source_metadata.core.workflow_layers == :full_valid_chain
    assert graph.source_metadata.core.product.id == "coding-agent"
    assert "catalyst.agent.default" in graph.source_metadata.core.product.packs
    assert byte_size(graph.source_metadata.core.product.digest) == 64
    assert byte_size(graph.snapshot_id) == 64
    assert repeated.snapshot_id == graph.snapshot_id

    assert Enum.any?(graph.claims, fn claim ->
             ServiceKey.to_wire(claim.key) == "agent.run_engine/default" and
               claim.owner == :builtin
           end)

    assert Enum.any?(graph.claims, fn claim ->
             claim.key.namespace == "llm" and claim.key.name == "provider" and
               claim.key.slot == "openai-codex-responses" and
               claim.owner == {:pack, "catalyst.provider.openai"} and
               claim.provenance ==
                 {:pack, "catalyst.provider.openai", {:provider, "openai-codex-responses"},
                  {:product, "coding-agent"}}
           end)

    assert Enum.any?(graph.contributions, fn contribution ->
             contribution.point == "agent.tool" and contribution.id == "runtime_graph" and
               contribution.owner == {:product, "coding-agent"} and
               contribution.provenance ==
                 {:product, "coding-agent", {:tool, "runtime_graph"}}
           end)
  end

  test "one failing source is reported without erasing healthy sources" do
    :ok = ReadModel.register_source(:broken_test_source, {String, :trim})

    graph = Runtime.snapshot()

    assert graph.source_status.core == :ready

    assert {:error, {:source_exception, %FunctionClauseError{}}} =
             graph.source_status.broken_test_source

    assert graph.claims != []
  end

  test "Runtime.explain/2 resolves from the aggregate graph" do
    key = ServiceKey.new!("agent", "run_engine", "default")
    explanation = Runtime.explain(key, session_id: "runtime-explain-test")

    assert explanation.status == :resolved
    assert explanation.selected.implementation == Catalyst.Agent.Loop
  end
end
