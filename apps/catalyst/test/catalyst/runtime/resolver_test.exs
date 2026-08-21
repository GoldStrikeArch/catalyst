defmodule Catalyst.Runtime.ResolverTest do
  use ExUnit.Case, async: true

  alias Catalyst.Runtime.{
    Claim,
    Context,
    ContractRef,
    Resolver,
    Scope,
    ServiceKey,
    Snapshot
  }

  @key ServiceKey.new!("agent", "run_engine", "default")
  @contract ContractRef.new!("catalyst.agent-run-engine", 1)

  test "a matching scoped claim hides a global fallback" do
    claims = [
      claim(:builtin, :global, 0),
      claim(:workspace, %{workspace_id: "w1"}, 100)
    ]

    assert {:ok, resolution} =
             Resolver.resolve(claims, @key, %{workspace_id: "w1"}, contract: @contract)

    assert resolution.claim.owner == :workspace
    assert Enum.map(resolution.explanation.hidden, & &1.owner) == [:builtin]
    assert resolution.binding == {:pin, :run}
  end

  test "scope, health, and contract rejections are explained" do
    incompatible =
      claim(:incompatible, :global, 300,
        contract: ContractRef.new!("catalyst.agent-run-engine", 2)
      )

    unhealthy = claim(:unhealthy, :global, 200, health: :unhealthy)
    other_workspace = claim(:other_workspace, %{workspace_id: "w2"}, 100)
    builtin = claim(:builtin, :global, 0)

    explanation =
      Resolver.explain(
        [incompatible, unhealthy, other_workspace, builtin],
        @key,
        %{workspace_id: "w1"},
        contract: @contract
      )

    assert explanation.selected.owner == :builtin

    assert Enum.map(explanation.rejected, fn rejection ->
             {rejection.claim.owner, rejection.reason}
           end) == [
             {:incompatible, {:incompatible_contract, incompatible.contract, @contract}},
             {:unhealthy, {:health, :unhealthy}},
             {:other_workspace, {:scope_mismatch, other_workspace.scope}}
           ]
  end

  test "equal specificity and priority are rejected as ambiguous" do
    claims = [claim(:one, :global, 100), claim(:two, :global, 100)]

    assert {:error, explanation} =
             Resolver.resolve(claims, @key, Context.new(%{}), contract: @contract)

    assert {:error, {:ambiguous_claims, conflicts}} = explanation.status
    assert length(conflicts) == 2
  end

  test "removing the selected claim exposes the next eligible claim" do
    selected = claim(:selected, %{session_id: "s1"}, 100)
    fallback = claim(:fallback, :global, 0)

    assert {:ok, first} =
             Resolver.resolve([selected, fallback], @key, %{session_id: "s1"},
               contract: @contract
             )

    assert first.claim.owner == :selected

    assert {:ok, second} =
             Resolver.resolve([fallback], @key, %{session_id: "s1"}, contract: @contract)

    assert second.claim.owner == :fallback
  end

  test "snapshot identity is independent of input-list order" do
    first = claim(:same_owner, :global, 100)
    second = %{first | metadata: %{variant: :second}}
    claims = [first, second]

    assert Snapshot.id(claims) == Snapshot.id(Enum.reverse(claims))
  end

  test "service keys round-trip through their wire representation" do
    wire = ServiceKey.to_wire(@key)
    assert {:ok, @key} == ServiceKey.parse(wire)

    assert {:error, {:invalid_service_key, "not-a-service-key"}} =
             ServiceKey.parse("not-a-service-key")

    assert {:ok, slash_slot} = ServiceKey.new("agent", "run_engine", "acp/claude")
    assert {:ok, ^slash_slot} = slash_slot |> ServiceKey.to_wire() |> ServiceKey.parse()

    assert {:ok, spaced_slot} = ServiceKey.new("agent", "run_engine", " review ")
    assert {:ok, ^spaced_slot} = spaced_slot |> ServiceKey.to_wire() |> ServiceKey.parse()

    assert {:error, {:invalid_service_key_part, :name, "bad/name"}} =
             ServiceKey.new("agent", "bad/name")
  end

  defp claim(owner, scope, priority, opts \\ []) do
    %Claim{
      key: @key,
      contract: Keyword.get(opts, :contract, @contract),
      implementation: {__MODULE__, owner},
      owner: owner,
      scope: scope(scope),
      priority: priority,
      binding: {:pin, :run},
      provenance: {:test, owner},
      health: Keyword.get(opts, :health, :ready)
    }
  end

  defp scope(:global), do: Scope.global()
  defp scope(constraints), do: Scope.new!(constraints)
end
