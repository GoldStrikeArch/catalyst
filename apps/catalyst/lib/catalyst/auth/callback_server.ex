defmodule Catalyst.Auth.CallbackServer do
  @moduledoc """
  Transient localhost HTTP server for the OAuth redirect. Bound to
  `127.0.0.1:1455` (the fixed Codex redirect URI), it serves a single
  `/auth/callback` route, validates `state`, captures `code`, and hands it to the
  waiting login process, then shuts down.
  """

  alias Catalyst.Auth.OpenAIOAuth

  @doc """
  Start the callback server, block until the redirect arrives (or `timeout`),
  then stop. Returns `{:ok, code}` or `{:error, reason}`.
  """
  def await(expected_state, timeout \\ 300_000) do
    parent = self()
    plug = {__MODULE__.Handler, %{parent: parent, state: expected_state}}

    case Bandit.start_link(
           plug: plug,
           scheme: :http,
           port: OpenAIOAuth.callback_port(),
           thousand_island_options: [transport_options: [ip: {127, 0, 0, 1}]],
           startup_log: false
         ) do
      {:ok, server} ->
        result =
          receive do
            {:oauth_code, code} -> {:ok, code}
            {:oauth_error, reason} -> {:error, reason}
          after
            timeout -> {:error, :timeout}
          end

        stop(server)
        result

      {:error, reason} ->
        {:error, {:callback_server, reason}}
    end
  end

  defp stop(server) do
    try do
      Supervisor.stop(server, :normal, 5_000)
    catch
      _, _ -> Process.exit(server, :kill)
    end
  end

  defmodule Handler do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/auth/callback"} = conn, %{parent: parent, state: expected}) do
      conn = fetch_query_params(conn)
      params = conn.query_params

      cond do
        params["error"] ->
          send(parent, {:oauth_error, params["error"]})
          respond(conn, error_html(params["error"]))

        params["state"] != expected ->
          send(parent, {:oauth_error, :state_mismatch})
          respond(conn, error_html("state mismatch"))

        is_binary(params["code"]) ->
          send(parent, {:oauth_code, params["code"]})
          respond(conn, success_html())

        true ->
          send(parent, {:oauth_error, :missing_code})
          respond(conn, error_html("missing code"))
      end
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")

    defp respond(conn, html) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, html)
    end

    defp success_html do
      page(
        "Signed in to Catalyst",
        "You're signed in. You can close this tab and return to the app."
      )
    end

    defp error_html(reason) do
      page(
        "Catalyst sign-in failed",
        "Sign-in failed: #{Plug.HTML.html_escape(to_string(reason))}."
      )
    end

    defp page(title, body) do
      """
      <!doctype html><html><head><meta charset="utf-8"><title>#{title}</title>
      <style>body{font-family:system-ui,sans-serif;background:#0b0b0f;color:#e7e7ea;
      display:grid;place-items:center;height:100vh;margin:0}.c{text-align:center;max-width:28rem}
      h1{font-size:1.25rem}p{color:#a1a1aa}</style></head>
      <body><div class="c"><h1>#{title}</h1><p>#{body}</p></div></body></html>
      """
    end
  end
end
