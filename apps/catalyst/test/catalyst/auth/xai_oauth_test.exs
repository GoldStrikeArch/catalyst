defmodule Catalyst.Auth.XAIOAuthTest do
  use ExUnit.Case, async: false

  alias Catalyst.Auth.{TokenStore, XAIOAuth}

  defmodule OAuthPlug do
    @moduledoc false

    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(%Plug.Conn{request_path: "/oauth2/device/code"} = conn, test_pid) do
      {:ok, body, conn} = read_body(conn)
      send(test_pid, {:device_request, URI.decode_query(body), conn.req_headers})

      json(conn, 200, %{
        "device_code" => "device-secret",
        "user_code" => "ABCD-EFGH",
        "verification_uri" => "https://accounts.x.ai/activate",
        "verification_uri_complete" => "https://accounts.x.ai/activate?code=ABCD-EFGH",
        "expires_in" => 600,
        "interval" => 2
      })
    end

    def call(%Plug.Conn{request_path: "/oauth2/token"} = conn, test_pid) do
      {:ok, body, conn} = read_body(conn)
      form = URI.decode_query(body)
      send(test_pid, {:token_request, form, conn.req_headers})
      json(conn, 200, token_response(form))
    end

    defp json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    defp jwt(payload) do
      encoded = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
      "header.#{encoded}.signature"
    end

    defp token_response(%{"grant_type" => "refresh_token"}) do
      %{
        "access_token" => jwt(%{"sub" => "xai-user-refreshed"}),
        "expires_in" => 3_600
      }
    end

    defp token_response(_device_grant) do
      %{
        "access_token" => jwt(%{"sub" => "xai-user-42"}),
        "refresh_token" => "refresh-secret",
        "expires_in" => 3_600
      }
    end
  end

  test "device authorization uses Grok Build's OAuth contract and returns stored credentials" do
    server =
      start_supervised!(
        {Bandit, plug: {OAuthPlug, self()}, scheme: :http, ip: :loopback, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    issuer = "http://127.0.0.1:#{port}"

    assert {:ok, device} = XAIOAuth.request_device_code(issuer: issuer)
    assert device.user_code == "ABCD-EFGH"
    assert device.verification_uri_complete =~ "ABCD-EFGH"

    assert_receive {:device_request, device_form, device_headers}
    assert device_form["client_id"] == "b1a00492-073a-47ea-816f-4c329264a828"
    assert device_form["scope"] =~ "grok-cli:access"
    assert device_form["scope"] =~ "offline_access"
    assert device_form["referrer"] == "grok-build"
    assert {"x-grok-client-surface", "ui"} in device_headers

    parent = self()

    assert {:ok, creds} =
             XAIOAuth.await_device_code(device,
               sleep: fn milliseconds -> send(parent, {:poll_delay, milliseconds}) end
             )

    assert_receive {:poll_delay, 2_000}
    assert_receive {:token_request, token_form, token_headers}

    assert token_form["grant_type"] ==
             "urn:ietf:params:oauth:grant-type:device_code"

    assert token_form["device_code"] == "device-secret"
    assert {"x-grok-client-surface", "ui"} in token_headers
    assert creds["refresh"] == "refresh-secret"
    assert creds["account_id"] == "xai-user-42"
    assert creds["issuer"] == issuer
    assert creds["expires"] > System.system_time(:millisecond)
  end

  test "TokenStore dispatches expired xAI credentials and preserves an unrotated refresh token" do
    server =
      start_supervised!(
        {Bandit, plug: {OAuthPlug, self()}, scheme: :http, ip: :loopback, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    issuer = "http://127.0.0.1:#{port}"
    provider = XAIOAuth.provider_id()

    :ok =
      TokenStore.put(provider, %{
        access: "expired-access",
        refresh: "original-refresh",
        expires: 0,
        account_id: "xai-user-old",
        issuer: issuer
      })

    on_exit(fn -> TokenStore.delete(provider) end)

    expected =
      {:ok, %{access: jwt(%{"sub" => "xai-user-refreshed"}), account_id: "xai-user-refreshed"}}

    assert ^expected = TokenStore.get_access_token(provider)

    assert_receive {:token_request, first_form, _headers}
    assert first_form["grant_type"] == "refresh_token"
    assert first_form["refresh_token"] == "original-refresh"

    :ok = TokenStore.invalidate(provider)
    assert ^expected = TokenStore.get_access_token(provider)

    assert_receive {:token_request, second_form, _headers}
    assert second_form["refresh_token"] == "original-refresh"
  end

  defp jwt(payload) do
    encoded = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    "header.#{encoded}.signature"
  end
end
