defmodule Catalyst.Auth.JWT do
  @moduledoc """
  Minimal JWT payload decode (no signature verification — matches PI's `decodeJwt`).
  Used only to read the ChatGPT account id from the Codex access token.
  """

  @claim_path "https://api.openai.com/auth"

  @doc "Decode the JWT payload (middle segment) into a claims map."
  @spec payload(term()) :: {:ok, map()} | {:error, term()}
  def payload(token) when is_binary(token) do
    case String.split(token, ".") do
      [_header, payload, _signature] -> decode_payload(payload)
      _segments -> {:error, :malformed_jwt}
    end
  end

  def payload(token), do: {:error, {:invalid_token, token}}

  @doc "Extract `chatgpt_account_id` from a Codex access token, or `nil` when absent."
  @spec account_id(term()) :: String.t() | nil
  def account_id(token) do
    case payload(token) do
      {:ok, claims} -> get_in(claims, [@claim_path, "chatgpt_account_id"])
      {:error, _reason} -> nil
    end
  end

  defp decode_payload(payload) do
    with {:ok, json} <- decode_base64(payload) do
      decode_claims(json)
    end
  end

  defp decode_base64(payload) do
    case Base.url_decode64(payload, padding: false) do
      {:ok, json} -> {:ok, json}
      :error -> {:error, :invalid_payload_encoding}
    end
  end

  defp decode_claims(json) do
    case Jason.decode(json) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      {:ok, other} -> {:error, {:invalid_claims, other}}
      {:error, reason} -> {:error, {:invalid_claims_json, reason}}
    end
  end
end
