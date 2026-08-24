defmodule Catalyst.ACP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Catalyst.ACP.Protocol

  test "classifies requests, notifications, and both response id types" do
    assert {:ok, {:request, "a", "method", %{"one" => 1}}} =
             Protocol.decode(~s({"jsonrpc":"2.0","id":"a","method":"method","params":{"one":1}}))

    assert {:ok, {:notification, "notice", %{}}} =
             Protocol.decode(~s({"jsonrpc":"2.0","method":"notice"}))

    assert {:ok, {:result, 1, %{"ok" => true}}} =
             Protocol.decode(~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}}))
  end

  test "rejects batches and malformed envelopes" do
    assert {:error, :batches_not_supported} = Protocol.decode("[]")
    assert {:error, {:invalid_jsonrpc, _value}} = Protocol.decode(~s({"jsonrpc":"1.0"}))

    assert {:error, {:invalid_params, []}} =
             Protocol.decode(~s({"jsonrpc":"2.0","method":"notice","params":[]}))

    assert {:error, {:malformed_json, _position}} = Protocol.decode("{")
  end
end
