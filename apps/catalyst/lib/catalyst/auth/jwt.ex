defmodule Catalyst.Auth.JWT do
  @moduledoc """
  Minimal JWT payload decode (no signature verification — matches PI's `decodeJwt`).
  Used only to read the ChatGPT account id from the Codex access token.
  """

  @claim_path "https://api.openai.com/auth"

  @doc "Decode the JWT payload (middle segment) into a claims map, or `nil`."
  def payload(token) when is_binary(token) do
    with [_header, payload, _sig] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      claims
    else
      _ -> nil
    end
  end

  def payload(_), do: nil

  @doc "Extract `chatgpt_account_id` from a Codex access token, or `nil`."
  def account_id(token) do
    case payload(token) do
      %{} = claims -> get_in(claims, [@claim_path, "chatgpt_account_id"])
      _ -> nil
    end
  end
end
