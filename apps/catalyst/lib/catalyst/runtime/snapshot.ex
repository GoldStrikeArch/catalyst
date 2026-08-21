defmodule Catalyst.Runtime.Snapshot do
  @moduledoc "Deterministic identity for an immutable collection of runtime claims."

  alias Catalyst.Runtime.Claim

  @doc """
  Return a SHA-256 digest for `claims`.

  Stable claim ordering makes the digest independent of input-list order.
  Runtime-specific terms such as PIDs or local functions remain runtime-specific
  and should not be used in durable manifests.
  """
  @spec id([Claim.t()]) :: String.t()
  def id(claims) when is_list(claims) do
    claims
    |> Enum.map(&:erlang.term_to_binary(&1, [:deterministic]))
    |> Enum.sort()
    |> term_id()
  end

  @doc "Return a deterministic runtime-local SHA-256 identity for an arbitrary term."
  @spec term_id(term()) :: String.t()
  def term_id(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
