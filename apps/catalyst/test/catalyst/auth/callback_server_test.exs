defmodule Catalyst.Auth.CallbackServerTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Catalyst.Auth.CallbackServer.Handler

  defp call(path) do
    conn(:get, path) |> Handler.call(%{parent: self(), state: "good_state"})
  end

  test "a request with the expected state and code resolves the login" do
    conn = call("/auth/callback?state=good_state&code=abc")
    assert conn.status == 200
    assert_received {:oauth_code, "abc"}
  end

  test "a provider error carrying the expected state resolves with that error" do
    conn = call("/auth/callback?state=good_state&error=access_denied")
    assert conn.status == 200
    assert_received {:oauth_error, "access_denied"}
  end

  test "a drive-by request without the expected state cannot abort the login" do
    for path <- [
          "/auth/callback?error=denied",
          "/auth/callback?state=wrong&code=evil",
          "/auth/callback"
        ] do
      conn = call(path)
      assert conn.status == 400
    end

    refute_received {:oauth_error, _}
    refute_received {:oauth_code, _}
  end
end
