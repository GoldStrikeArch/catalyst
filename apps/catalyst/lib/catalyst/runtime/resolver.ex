defmodule Catalyst.Runtime.Resolver do
  @moduledoc """
  Pure deterministic resolution of runtime service claims.

  Resolution filters by key, contract, health, and scope. The most specific
  scope wins, followed by explicit priority. Equal-ranked claims are rejected
  as ambiguous rather than being ordered by installation time.
  """

  alias Catalyst.Runtime.{
    Claim,
    Context,
    ContractRef,
    Explanation,
    Resolution,
    Scope,
    ServiceKey,
    Snapshot
  }

  @doc "Resolve one service key from an immutable claim collection."
  @spec resolve([Claim.t()], ServiceKey.t(), Context.t() | map() | keyword(), keyword()) ::
          {:ok, Resolution.t()} | {:error, Explanation.t()}
  def resolve(claims, %ServiceKey{} = key, context, opts \\ []) when is_list(claims) do
    explanation = explain(claims, key, context, opts)

    case explanation do
      %Explanation{selected: %Claim{} = claim, contract: %ContractRef{} = contract} ->
        {:ok,
         %Resolution{
           key: key,
           contract: contract,
           claim: claim,
           binding: claim.binding,
           snapshot_id: explanation.snapshot_id,
           explanation: explanation
         }}

      %Explanation{} ->
        {:error, explanation}
    end
  end

  @doc "Explain every accepted and rejected candidate for one service key."
  @spec explain([Claim.t()], ServiceKey.t(), Context.t() | map() | keyword(), keyword()) ::
          Explanation.t()
  def explain(claims, %ServiceKey{} = key, context, opts \\ []) when is_list(claims) do
    context = Context.new(context)
    contract = Keyword.get(opts, :contract)
    {eligible, rejected} = evaluate(claims, key, contract, context)
    ranked = Enum.sort_by(eligible, &{rank(&1), Claim.stable_key(&1)}, :desc)
    snapshot_id = Snapshot.id(claims)

    case select(ranked) do
      {:ok, selected, hidden} ->
        explanation(
          key,
          contract || selected.contract,
          context,
          selected,
          hidden,
          rejected,
          snapshot_id
        )

      {:error, reason} ->
        %Explanation{
          key: key,
          contract: contract,
          context: context,
          selected: nil,
          hidden: ranked,
          rejected: rejected,
          status: {:error, reason},
          snapshot_id: snapshot_id
        }
    end
  end

  defp evaluate(claims, key, contract, context) do
    claims
    |> Enum.filter(&(&1.key == key))
    |> Enum.reduce({[], []}, fn claim, {eligible, rejected} ->
      case rejection_reason(claim, contract, context) do
        nil -> {[claim | eligible], rejected}
        reason -> {eligible, [%{claim: claim, reason: reason} | rejected]}
      end
    end)
    |> then(fn {eligible, rejected} ->
      {Enum.reverse(eligible), Enum.reverse(rejected)}
    end)
  end

  defp rejection_reason(%Claim{} = claim, contract, context) do
    cond do
      claim.health != :ready ->
        {:health, claim.health}

      match?(%ContractRef{}, contract) and
          not ContractRef.compatible?(claim.contract, contract) ->
        {:incompatible_contract, claim.contract, contract}

      not Scope.matches?(claim.scope, context) ->
        {:scope_mismatch, claim.scope}

      true ->
        nil
    end
  end

  defp rank(%Claim{} = claim), do: {Scope.specificity(claim.scope), claim.priority}

  defp select([]), do: {:error, :no_matching_claim}

  defp select([selected | rest]) do
    conflicts = Enum.take_while(rest, &(rank(&1) == rank(selected)))

    case conflicts do
      [] -> {:ok, selected, rest}
      claims -> {:error, {:ambiguous_claims, Enum.map([selected | claims], &Claim.stable_key/1)}}
    end
  end

  defp explanation(key, contract, context, selected, hidden, rejected, snapshot_id) do
    %Explanation{
      key: key,
      contract: contract,
      context: context,
      selected: selected,
      hidden: hidden,
      rejected: rejected,
      status: :resolved,
      snapshot_id: snapshot_id
    }
  end
end
