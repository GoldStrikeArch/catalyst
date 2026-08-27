defmodule Catalyst.Auth.XAIOAuth do
  @moduledoc """
  xAI device OAuth for subscription access used by Grok Build.

  The protocol constants and headers mirror Grok Build's public client. Device
  codes and token responses are validated at this boundary before credentials
  enter `Catalyst.Auth.TokenStore`.
  """

  alias Catalyst.Auth.JWT

  @provider_id "xai-grok"
  @issuer "https://auth.x.ai"
  # Version of the Grok Build CLI whose wire protocol these headers mirror. xAI's
  # proxy rejects clients that report an older version (HTTP 426), so this must
  # track the published CLI — it is deliberately NOT Catalyst's own version.
  @client_version "1.0.5"
  @client_id "b1a00492-073a-47ea-816f-4c329264a828"
  @scope Enum.join(
           ~w(openid profile email offline_access grok-cli:access api:access conversations:read conversations:write workspaces:read workspaces:write),
           " "
         )
  @fallback_expires_in 30 * 24 * 60 * 60

  @typedoc "Validated device authorization details."
  @type device_code :: %{
          device_code: String.t(),
          user_code: String.t(),
          verification_uri: String.t(),
          verification_uri_complete: String.t() | nil,
          expires_in: pos_integer(),
          interval: pos_integer(),
          issuer: String.t(),
          client_id: String.t()
        }

  @typedoc "Stored credentials accepted by `Catalyst.Auth.TokenStore`."
  @type credentials :: %{required(String.t()) => String.t() | integer() | nil}

  @doc "Provider identity for this flow — the `Catalyst.Auth.TokenStore` key."
  @spec provider_id() :: String.t()
  def provider_id, do: @provider_id

  @doc """
  Grok Build client version sent as `x-grok-client-version` on every xAI request.

  Defaults to the bundled constant; override with `config :catalyst,
  :grok_client_version` when the proxy raises its minimum before a release ships.
  """
  @spec client_version() :: String.t()
  def client_version,
    do: Application.get_env(:catalyst, :grok_client_version, @client_version)

  @doc "Request a device code from xAI."
  @spec request_device_code(keyword()) :: {:ok, device_code()} | {:error, term()}
  def request_device_code(opts \\ []) do
    issuer = issuer(opts)
    client_id = Keyword.get(opts, :client_id, @client_id)
    form = %{"client_id" => client_id, "scope" => @scope, "referrer" => "grok-build"}

    case Req.post(issuer <> "/oauth2/device/code",
           form: form,
           headers: client_headers(),
           receive_timeout: 30_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        device_code_from(body, issuer, client_id)

      {:ok, %{status: status, body: body}} ->
        {:error, oauth_http_error(:device_code, status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Poll xAI until the device authorization completes or expires."
  @spec await_device_code(device_code(), keyword()) :: {:ok, credentials()} | {:error, term()}
  def await_device_code(device, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + device.expires_in * 1_000
    poll(device, device.interval, deadline, opts)
  end

  @doc "Refresh credentials issued by xAI, preserving a non-rotated refresh token."
  @spec refresh(map()) :: {:ok, credentials()} | {:error, term()}
  def refresh(creds) when is_map(creds) do
    issuer = creds["issuer"] || @issuer
    client_id = creds["client_id"] || @client_id

    form = %{
      "grant_type" => "refresh_token",
      "refresh_token" => creds["refresh"],
      "client_id" => client_id
    }

    with {:ok, body} <- post_token(issuer, form),
         {:ok, refreshed} <- credentials_from(body, issuer, client_id, creds["refresh"]) do
      {:ok, refreshed}
    end
  end

  defp poll(device, interval, deadline, opts) do
    now = System.monotonic_time(:millisecond)

    case now + interval * 1_000 >= deadline do
      true ->
        {:error, :device_code_expired}

      false ->
        sleep(opts, interval * 1_000)
        poll_once(device, interval, deadline, opts)
    end
  end

  defp poll_once(device, interval, deadline, opts) do
    form = %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
      "device_code" => device.device_code,
      "client_id" => device.client_id
    }

    case post_token(device.issuer, form) do
      {:ok, body} ->
        credentials_from(body, device.issuer, device.client_id)

      {:error, {:oauth, "authorization_pending", _description}} ->
        poll(device, interval, deadline, opts)

      {:error, {:oauth, "slow_down", _description}} ->
        poll(device, interval + 5, deadline, opts)

      {:error, {:oauth, "access_denied", description}} ->
        {:error, {:access_denied, description}}

      {:error, {:oauth, "expired_token", _description}} ->
        {:error, :device_code_expired}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post_token(issuer, form) do
    case Req.post(issuer <> "/oauth2/token",
           form: form,
           headers: client_headers(),
           receive_timeout: 30_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{body: %{"error" => error} = body}} -> {:error, oauth_error(error, body)}
      {:ok, %{status: status, body: body}} -> {:error, oauth_http_error(:token, status, body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp device_code_from(
         %{
           "device_code" => device_code,
           "user_code" => user_code,
           "verification_uri" => verification_uri,
           "expires_in" => expires_in
         } = body,
         issuer,
         client_id
       )
       when is_binary(device_code) and device_code != "" and is_binary(user_code) and
              user_code != "" and is_binary(verification_uri) and verification_uri != "" and
              is_integer(expires_in) and expires_in > 0 do
    with :ok <- validate_https_uri(verification_uri),
         {:ok, complete} <- optional_https_uri(body["verification_uri_complete"]) do
      {:ok,
       %{
         device_code: device_code,
         user_code: user_code,
         verification_uri: verification_uri,
         verification_uri_complete: complete,
         expires_in: expires_in,
         interval: positive_integer(body["interval"], 5),
         issuer: issuer,
         client_id: client_id
       }}
    end
  end

  defp device_code_from(%{} = body, _issuer, _client_id),
    do: {:error, {:device_code_response_missing_fields, Map.keys(body)}}

  defp device_code_from(_body, _issuer, _client_id),
    do: {:error, {:device_code_response_missing_fields, []}}

  defp credentials_from(body, issuer, client_id, fallback_refresh \\ nil)

  defp credentials_from(%{"access_token" => access} = body, issuer, client_id, fallback_refresh)
       when is_binary(access) and access != "" do
    refresh = body["refresh_token"] || fallback_refresh

    case refresh do
      value when is_binary(value) and value != "" ->
        expires_in = positive_integer(body["expires_in"], @fallback_expires_in)

        {:ok,
         %{
           "access" => access,
           "refresh" => value,
           "expires" => System.system_time(:millisecond) + expires_in * 1_000,
           "account_id" => subject(body["id_token"]) || subject(access),
           "issuer" => issuer,
           "client_id" => client_id
         }}

      _missing ->
        {:error, {:token_response_missing_fields, Map.keys(body)}}
    end
  end

  defp credentials_from(%{} = body, _issuer, _client_id, _fallback_refresh),
    do: {:error, {:token_response_missing_fields, Map.keys(body)}}

  defp credentials_from(_body, _issuer, _client_id, _fallback_refresh),
    do: {:error, {:token_response_missing_fields, []}}

  defp subject(token) when is_binary(token) do
    case JWT.payload(token) do
      {:ok, %{"sub" => subject}} when is_binary(subject) and subject != "" -> subject
      _invalid_or_missing -> nil
    end
  end

  defp subject(_token), do: nil

  defp optional_https_uri(nil), do: {:ok, nil}

  defp optional_https_uri(uri) when is_binary(uri) do
    case validate_https_uri(uri) do
      :ok -> {:ok, uri}
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_https_uri(_uri), do: {:error, :invalid_verification_uri}

  defp validate_https_uri(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      _invalid -> {:error, :invalid_verification_uri}
    end
  end

  defp oauth_error(error, body),
    do: {:oauth, to_string(error), body["error_description"]}

  defp oauth_http_error(:device_code, status, %{} = body),
    do: {:device_code_http, status, Map.keys(body)}

  defp oauth_http_error(:device_code, status, _body), do: {:device_code_http, status, []}
  defp oauth_http_error(:token, status, %{} = body), do: {:token_http, status, Map.keys(body)}
  defp oauth_http_error(:token, status, _body), do: {:token_http, status, []}

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, fallback), do: fallback

  defp issuer(opts),
    do: Keyword.get(opts, :issuer, Application.get_env(:catalyst, :xai_oauth_issuer, @issuer))

  defp sleep(opts, milliseconds) do
    opts
    |> Keyword.get(:sleep, &Process.sleep/1)
    |> then(& &1.(milliseconds))
  end

  defp client_headers do
    [
      {"x-grok-client-version", client_version()},
      {"x-grok-client-surface", "ui"},
      {"accept", "application/json"}
    ]
  end
end
