defmodule Catalyst.Auth.CallbackServerTest do
  # async: false — the supersede test flips the :oauth_callback_port app env
  # and binds a real TCP port.
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [wait_until: 1]
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

  test "a new login supersedes an abandoned one instead of holding the port for 5 minutes" do
    # A real (random) port so this test can't collide with a dev instance.
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    Application.put_env(:catalyst, :oauth_callback_port, port)
    on_exit(fn -> Application.delete_env(:catalyst, :oauth_callback_port) end)

    abandoned =
      Task.async(fn ->
        {:ok, callback} = Catalyst.Auth.CallbackServer.start("state1")
        Catalyst.Auth.CallbackServer.await(callback, 30_000)
      end)

    # Wait for the first server to be up and registered.
    wait_until(fn ->
      :persistent_term.get({Catalyst.Auth.CallbackServer, :current}, nil) != nil
    end)

    # The second attempt binds the SAME port immediately (no address-in-use)
    # and kicks the first waiter loose.
    second =
      Task.async(fn ->
        {:ok, callback} = Catalyst.Auth.CallbackServer.start("state2")
        Catalyst.Auth.CallbackServer.await(callback, 30_000)
      end)

    assert {:error, :superseded} = Task.await(abandoned, 5_000)

    # Drive the second flow to completion through the real HTTP server.
    wait_until(fn ->
      match?(
        {:ok, %{status: 200}},
        Req.get("http://127.0.0.1:#{port}/auth/callback",
          params: [state: "state2", code: "abc"],
          retry: false
        )
      )
    end)

    assert {:ok, "abc"} = Task.await(second, 5_000)
  end
end
