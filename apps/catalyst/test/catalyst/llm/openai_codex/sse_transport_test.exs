defmodule Catalyst.LLM.OpenAICodex.SSETransportTest do
  use ExUnit.Case, async: false

  alias Catalyst.LLM.OpenAICodex.SSETransport
  alias Catalyst.Test.SSEErrorPlug

  test "caps non-success response bodies" do
    server =
      start_supervised!({Bandit, plug: SSEErrorPlug, scheme: :http, ip: :loopback, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}/codex/responses"

    assert {:http_error, 418, body} =
             SSETransport.stream(url, [], %{"model" => "gpt-test"}, fn _ -> :ok end, "sse-cap")

    assert byte_size(body) == 65_536
    assert body == String.duplicate("x", 65_536)
  end
end
