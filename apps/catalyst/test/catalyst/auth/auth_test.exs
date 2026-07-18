defmodule Catalyst.AuthTest do
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]

  alias Catalyst.Auth.{CallbackServer, JWT, OpenAIOAuth, PKCE, TokenStore}

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

  test "OAuth binds the callback listener before launching the browser" do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    Application.put_env(:catalyst, :oauth_callback_port, port)
    parent = self()

    on_exit(fn ->
      Application.delete_env(:catalyst, :oauth_callback_port)
      :persistent_term.erase({CallbackServer, :current})
    end)

    result =
      Catalyst.Auth.login_openai_codex(
        open_browser: fn url ->
          {:ok, connected} = :gen_tcp.connect(~c"127.0.0.1", port, [], 1_000)
          :gen_tcp.close(connected)
          send(parent, :listener_ready)

          state =
            url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

          assert {:ok, %{status: 200}} =
                   Req.get("http://127.0.0.1:#{port}/auth/callback",
                     params: [state: state, error: "access_denied"],
                     retry: false
                   )
        end
      )

    assert_received :listener_ready
    assert result == {:error, "access_denied"}
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

  test "TokenStore persists auth credentials with mode 0600" do
    provider = "mode-provider"
    on_exit(fn -> TokenStore.delete(provider) end)

    assert :ok =
             TokenStore.put(provider, %{
               access: "secret_access",
               refresh: "secret_refresh",
               expires: System.system_time(:millisecond) + 3_600_000,
               account_id: "acct_mode"
             })

    path = Application.fetch_env!(:catalyst, :auth_path)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert band(mode, 0o7777) == 0o600
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
      send(test_pid, {:refresh_started, self()})

      receive do
        :never_sent -> {:error, :unexpected}
      end
    end)

    on_exit(fn -> Application.delete_env(:catalyst, :oauth_refresh_fun) end)

    TokenStore.put("race-provider", %{
      access: "old",
      refresh: "ref_1",
      expires: 0,
      account_id: "acct_old"
    })

    waiter = Task.async(fn -> TokenStore.get_access_token("race-provider") end)
    assert_receive {:refresh_started, refresh_pid}, 1_000
    ref = Process.monitor(refresh_pid)

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
    assert_receive {:DOWN, ^ref, :process, ^refresh_pid, :killed}, 1_000

    # The stale refresh was killed, so it cannot clobber the fresh login.
    assert {:ok, %{access: "from_fresh_login", account_id: "acct_new"}} =
             TokenStore.get_access_token("race-provider")
  end

  test "delete during an in-flight refresh discards the refresh result" do
    test_pid = self()

    Application.put_env(:catalyst, :oauth_refresh_fun, fn _refresh_token ->
      send(test_pid, {:refresh_started, self()})

      receive do
        :finish_refresh -> :ok
      after
        1_000 -> :ok
      end

      {:ok,
       %{
         "access" => "from_deleted_refresh",
         "refresh" => "rotated_ref",
         "expires" => System.system_time(:millisecond) + 3_600_000,
         "account_id" => "acct_deleted"
       }}
    end)

    on_exit(fn ->
      Application.delete_env(:catalyst, :oauth_refresh_fun)
      TokenStore.delete("delete-race-provider")
    end)

    TokenStore.put("delete-race-provider", %{
      access: "old",
      refresh: "ref_1",
      expires: 0,
      account_id: "acct_old"
    })

    waiter = Task.async(fn -> TokenStore.get_access_token("delete-race-provider") end)
    assert_receive {:refresh_started, refresh_pid}, 1_000
    ref = Process.monitor(refresh_pid)

    assert :ok = TokenStore.delete("delete-race-provider")
    assert {:error, :not_logged_in} = Task.await(waiter)

    assert_receive {:DOWN, ^ref, :process, ^refresh_pid, :killed}, 1_000

    refute TokenStore.logged_in?("delete-race-provider")
    assert {:error, :not_logged_in} = TokenStore.get_access_token("delete-race-provider")
  end

  test "a hung refresh is killed at the deadline and releases every waiter" do
    test_pid = self()
    provider = "timeout-provider"

    Application.put_env(:catalyst, :oauth_refresh_timeout, 30)

    Application.put_env(:catalyst, :oauth_refresh_fun, fn _refresh_token ->
      send(test_pid, {:refresh_started, self()})

      receive do
        :never_sent -> {:error, :unexpected}
      end
    end)

    on_exit(fn ->
      Application.delete_env(:catalyst, :oauth_refresh_timeout)
      Application.delete_env(:catalyst, :oauth_refresh_fun)
      TokenStore.delete(provider)
    end)

    TokenStore.put(provider, %{
      access: "old",
      refresh: "ref_1",
      expires: 0,
      account_id: "acct"
    })

    first = Task.async(fn -> TokenStore.get_access_token(provider) end)
    second = Task.async(fn -> TokenStore.get_access_token(provider) end)

    assert_receive {:refresh_started, refresh_pid}, 1_000
    ref = Process.monitor(refresh_pid)

    expected = {:error, {:refresh_failed, :timeout}}
    assert ^expected = Task.await(first)
    assert ^expected = Task.await(second)
    assert_receive {:DOWN, ^ref, :process, ^refresh_pid, :killed}, 1_000
  end

  test "a completed refresh queued at the timeout boundary is preserved" do
    test_pid = self()
    provider = "timeout-boundary-provider"

    Application.put_env(:catalyst, :oauth_refresh_fun, fn _refresh_token ->
      send(test_pid, {:boundary_refresh_started, self()})

      receive do
        :finish_boundary_refresh ->
          {:ok,
           %{
             "access" => "rotated_access",
             "refresh" => "rotated_refresh",
             "expires" => System.system_time(:millisecond) + 3_600_000,
             "account_id" => "rotated_account"
           }}
      end
    end)

    on_exit(fn ->
      resume_if_suspended(TokenStore)
      Application.delete_env(:catalyst, :oauth_refresh_fun)
      TokenStore.delete(provider)
    end)

    TokenStore.put(provider, %{
      access: "old",
      refresh: "old_refresh",
      expires: 0,
      account_id: "old_account"
    })

    waiter = Task.async(fn -> TokenStore.get_access_token(provider) end)
    assert_receive {:boundary_refresh_started, worker}, 1_000

    %{refreshing: refreshing} = :sys.get_state(TokenStore)
    ref = refreshing[provider].task.ref
    monitor = Process.monitor(worker)
    :ok = :sys.suspend(TokenStore)

    send(TokenStore, {:refresh_timeout, provider, ref})
    send(worker, :finish_boundary_refresh)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000

    :ok = :sys.resume(TokenStore)

    expected = {:ok, %{access: "rotated_access", account_id: "rotated_account"}}
    assert ^expected = Task.await(waiter)
    assert ^expected = TokenStore.get_access_token(provider)
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

  test "TokenStore put and delete propagate persistence errors" do
    provider = "unwritable-provider"
    path = Application.fetch_env!(:catalyst, :auth_path)
    on_exit(fn -> File.rm_rf!(path) end)

    # Make auth path unwritable (replace with a directory)
    File.rm_rf!(path)
    File.mkdir_p!(path)

    creds = %{access: "a", refresh: "r", expires: 0, account_id: "id"}
    assert {:error, _} = TokenStore.put(provider, creds)
    # Even if put failed to persist, it shouldn't have clobbered memory with bad state?
    # Actually our implementation currently returns error and keeps OLD state.

    # Now fix it, put something, then break it again for delete.
    File.rm_rf!(path)
    assert :ok = TokenStore.put(provider, creds)

    File.rm!(path)
    File.mkdir_p!(path)
    assert {:error, _} = TokenStore.delete(provider)
  end

  defp resume_if_suspended(server) do
    case Process.whereis(server) do
      pid when is_pid(pid) -> resume_pid_if_suspended(pid)
      nil -> :ok
    end
  end

  defp resume_pid_if_suspended(pid) do
    case Process.info(pid, :status) do
      {:status, :suspended} -> :sys.resume(pid)
      _not_suspended -> :ok
    end
  end
end
