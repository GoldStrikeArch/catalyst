defmodule Catalyst.Auth.CallbackServer.Handler do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/auth/callback"} = conn, %{parent: parent, state: expected}) do
    conn = fetch_query_params(conn)
    params = conn.query_params

    cond do
      params["state"] != expected ->
        respond(conn, 400, error_html("state mismatch"))

      params["error"] ->
        send(parent, {:oauth_error, params["error"]})
        respond(conn, 200, error_html(params["error"]))

      is_binary(params["code"]) ->
        send(parent, {:oauth_code, params["code"]})
        respond(conn, 200, success_html())

      true ->
        respond(conn, 400, error_html("missing code"))
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "not found")

  defp respond(conn, status, html) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
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
