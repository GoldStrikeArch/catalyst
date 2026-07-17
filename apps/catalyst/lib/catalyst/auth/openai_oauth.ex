defmodule Catalyst.Auth.OpenAIOAuth do
  @moduledoc """
  ChatGPT (Codex subscription) OAuth — constants and endpoints taken verbatim
  from PI's `openai-codex.ts`. PKCE authorization-code flow with a localhost
  callback; access tokens are JWTs carrying the ChatGPT account id.
  """

  alias Catalyst.Auth.JWT

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @auth_base "https://auth.openai.com"
  @authorize_url @auth_base <> "/oauth/authorize"
  @token_url @auth_base <> "/oauth/token"
  @redirect_uri "http://localhost:1455/auth/callback"
  @scope "openid profile email offline_access"
  @callback_port 1455

  @typedoc "Stored credentials: access/refresh tokens, expiry (ms), account id."
  @type credentials :: %{required(String.t()) => String.t() | integer() | nil}

  @doc "The Codex CLI OAuth client id."
  @spec client_id() :: String.t()
  def client_id, do: @client_id

  @doc "The fixed localhost redirect URI registered for the Codex client."
  @spec redirect_uri() :: String.t()
  def redirect_uri, do: @redirect_uri

  @doc "The localhost port the redirect URI points at."
  @spec callback_port() :: :inet.port_number()
  def callback_port, do: @callback_port

  @doc "Build the browser authorization URL for a PKCE challenge + state."
  @spec authorize_url(String.t(), String.t(), String.t()) :: String.t()
  def authorize_url(challenge, state, originator \\ "catalyst") do
    query =
      URI.encode_query([
        {"response_type", "code"},
        {"client_id", @client_id},
        {"redirect_uri", @redirect_uri},
        {"scope", @scope},
        {"code_challenge", challenge},
        {"code_challenge_method", "S256"},
        {"state", state},
        {"id_token_add_organizations", "true"},
        {"codex_cli_simplified_flow", "true"},
        {"originator", originator}
      ])

    @authorize_url <> "?" <> query
  end

  @doc "Exchange an authorization code for credentials."
  @spec exchange_code(String.t(), String.t()) :: {:ok, credentials()} | {:error, term()}
  def exchange_code(code, verifier) do
    post_token(%{
      "grant_type" => "authorization_code",
      "client_id" => @client_id,
      "code" => code,
      "code_verifier" => verifier,
      "redirect_uri" => @redirect_uri
    })
  end

  @doc "Refresh an access token from a refresh token."
  @spec refresh(String.t()) :: {:ok, credentials()} | {:error, term()}
  def refresh(refresh_token) do
    post_token(%{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => @client_id
    })
  end

  defp post_token(form) do
    case Req.post(@token_url, form: form, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} -> credentials_from(body)
      {:ok, %{status: status, body: body}} -> {:error, {:token_http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp credentials_from(%{
         "access_token" => access,
         "refresh_token" => refresh,
         "expires_in" => expires_in
       })
       when is_binary(access) and is_binary(refresh) and is_integer(expires_in) do
    {:ok,
     %{
       "access" => access,
       "refresh" => refresh,
       "expires" => System.system_time(:millisecond) + expires_in * 1000,
       "account_id" => JWT.account_id(access)
     }}
  end

  # Only the KEYS go in the error: the body may carry a live access_token, and
  # this tuple ends up in logs and rendered chat content.
  defp credentials_from(%{} = body),
    do: {:error, {:token_response_missing_fields, Map.keys(body)}}

  defp credentials_from(_body), do: {:error, {:token_response_missing_fields, []}}
end
