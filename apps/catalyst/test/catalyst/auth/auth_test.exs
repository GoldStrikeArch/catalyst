defmodule Catalyst.AuthTest do
  use ExUnit.Case, async: false

  alias Catalyst.Auth.{JWT, OpenAIOAuth, PKCE, TokenStore}

  test "PKCE generates a verifier and a distinct S256 challenge" do
    %{verifier: v, challenge: c} = PKCE.generate()
    assert byte_size(v) >= 43
    assert v != c
    # challenge is base64url(sha256(verifier))
    expected = :sha256 |> :crypto.hash(v) |> Base.url_encode64(padding: false)
    assert c == expected
  end

  test "JWT.account_id reads the chatgpt account id claim" do
    claims = %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct_42"}}
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    token = "header.#{payload}.sig"

    assert JWT.account_id(token) == "acct_42"
    assert JWT.account_id("not-a-jwt") == nil
  end

  test "authorize_url carries the PKCE and Codex flow params" do
    url = OpenAIOAuth.authorize_url("CHAL", "STATE")
    assert url =~ "code_challenge=CHAL"
    assert url =~ "code_challenge_method=S256"
    assert url =~ "state=STATE"
    assert url =~ "response_type=code"
    assert url =~ "codex_cli_simplified_flow=true"
    assert url =~ "client_id=app_EMoamEEZ73f0CkXaXp7hrann"
  end

  test "TokenStore stores and returns a fresh access token" do
    creds = %{
      access: "tok_abc",
      refresh: "ref_abc",
      expires: System.system_time(:millisecond) + 3_600_000,
      account_id: "acct_42"
    }

    assert :ok = TokenStore.put("test-provider", creds)
    assert TokenStore.logged_in?("test-provider")

    assert {:ok, %{access: "tok_abc", account_id: "acct_42"}} =
             TokenStore.get_access_token("test-provider")

    assert {:error, :not_logged_in} = TokenStore.get_access_token("nope-provider")
  end

  test "stale tokens refresh single-flight without blocking other calls" do
    test_pid = self()

    Application.put_env(:catalyst, :oauth_refresh_fun, fn refresh_token ->
      send(test_pid, {:refresh_called, refresh_token})
      Process.sleep(300)

      {:ok,
       %{
         "access" => "new_access",
         "refresh" => "new_refresh",
         "expires" => System.system_time(:millisecond) + 3_600_000,
         # nil: the stored account id must be preserved across the refresh
         "account_id" => nil
       }}
    end)

    on_exit(fn -> Application.delete_env(:catalyst, :oauth_refresh_fun) end)

    TokenStore.put("stale-provider", %{
      access: "old",
      refresh: "ref_1",
      expires: 0,
      account_id: "acct_keep"
    })

    t1 = Task.async(fn -> TokenStore.get_access_token("stale-provider") end)
    t2 = Task.async(fn -> TokenStore.get_access_token("stale-provider") end)

    # While the refresh is in flight the server must keep answering other calls.
    assert TokenStore.logged_in?("stale-provider")

    assert {:ok, %{access: "new_access", account_id: "acct_keep"}} = Task.await(t1)
    assert {:ok, %{access: "new_access", account_id: "acct_keep"}} = Task.await(t2)

    # Single-flight: both callers were served by ONE refresh.
    assert_received {:refresh_called, "ref_1"}
    refute_received {:refresh_called, _}
  end

  test "a fresh login during an in-flight refresh supersedes the refresh result" do
    test_pid = self()

    Application.put_env(:catalyst, :oauth_refresh_fun, fn _refresh_token ->
      send(test_pid, :refresh_started)
      Process.sleep(200)

      {:ok,
       %{
         "access" => "from_stale_refresh",
         "refresh" => "rotated_ref",
         "expires" => System.system_time(:millisecond) + 3_600_000,
         "account_id" => nil
       }}
    end)

    on_exit(fn -> Application.delete_env(:catalyst, :oauth_refresh_fun) end)

    TokenStore.put("race-provider", %{
      access: "old",
      refresh: "ref_1",
      expires: 0,
      account_id: "acct_old"
    })

    waiter = Task.async(fn -> TokenStore.get_access_token("race-provider") end)
    assert_receive :refresh_started, 1_000

    # A fresh login lands while the refresh is still in flight.
    fresh = %{
      access: "from_fresh_login",
      refresh: "fresh_ref",
      expires: System.system_time(:millisecond) + 3_600_000,
      account_id: "acct_new"
    }

    assert :ok = TokenStore.put("race-provider", fresh)

    # The queued caller is released immediately with the fresh-login creds.
    assert {:ok, %{access: "from_fresh_login", account_id: "acct_new"}} = Task.await(waiter)

    # After the superseded refresh completes, its result must be discarded —
    # with refresh-token rotation it could be dead credentials.
    Process.sleep(300)

    assert {:ok, %{access: "from_fresh_login", account_id: "acct_new"}} =
             TokenStore.get_access_token("race-provider")
  end

  test "invalidate/1 forces the next get_access_token to refresh" do
    test_pid = self()

    Application.put_env(:catalyst, :oauth_refresh_fun, fn refresh_token ->
      send(test_pid, {:refresh_called, refresh_token})

      {:ok,
       %{
         "access" => "refreshed",
         "refresh" => "ref_2",
         "expires" => System.system_time(:millisecond) + 3_600_000,
         "account_id" => nil
       }}
    end)

    on_exit(fn -> Application.delete_env(:catalyst, :oauth_refresh_fun) end)

    TokenStore.put("invalidate-provider", %{
      access: "looks_fresh_but_revoked",
      refresh: "ref_1",
      expires: System.system_time(:millisecond) + 3_600_000,
      account_id: "acct"
    })

    # Fresh by expiry, so no refresh happens yet.
    assert {:ok, %{access: "looks_fresh_but_revoked"}} =
             TokenStore.get_access_token("invalidate-provider")

    refute_received {:refresh_called, _}

    assert :ok = TokenStore.invalidate("invalidate-provider")
    # Unknown providers are a no-op.
    assert :ok = TokenStore.invalidate("never-stored")

    assert {:ok, %{access: "refreshed", account_id: "acct"}} =
             TokenStore.get_access_token("invalidate-provider")

    assert_received {:refresh_called, "ref_1"}
  end
end
