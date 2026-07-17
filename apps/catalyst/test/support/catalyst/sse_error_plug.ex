defmodule Catalyst.Test.SSEErrorPlug do
  @moduledoc false

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Conn.send_resp(conn, 418, String.duplicate("x", 100_000))
  end
end
