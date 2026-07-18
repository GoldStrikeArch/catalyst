defmodule CatalystWeb.Flex.HttpPlug do
  @moduledoc "A local text-only Plug used by checked guide examples."

  @behaviour Plug

  @impl true
  def init(body), do: body

  @impl true
  def call(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(200, body)
  end
end
