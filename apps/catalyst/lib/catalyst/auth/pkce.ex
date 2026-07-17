defmodule Catalyst.Auth.PKCE do
  @moduledoc "PKCE (RFC 7636) verifier/challenge and OAuth state, matching the Codex CLI flow."

  @doc "A fresh `%{verifier, challenge}` pair (S256)."
  @spec generate() :: %{verifier: String.t(), challenge: String.t()}
  def generate do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    %{verifier: verifier, challenge: challenge}
  end

  @doc "A random opaque `state` value."
  @spec state() :: String.t()
  def state, do: Catalyst.Ids.hex(16)
end
