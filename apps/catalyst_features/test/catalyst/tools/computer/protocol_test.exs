defmodule Catalyst.Tools.Computer.ProtocolTest do
  use ExUnit.Case, async: true
  doctest Catalyst.Tools.Computer.Protocol
  alias Catalyst.Tools.Computer.Protocol

  describe "encode/3 + decode_line/1 round-trip" do
    test "request survives a round-trip" do
      line = Protocol.encode(42, "click", %{"coordinate" => [10, 20], "count" => 2})
      assert {:request, 42, "click", args} = Protocol.decode_line(line)
      assert args == %{"coordinate" => [10, 20], "count" => 2}
    end

    test "atom-keyed args are stringified" do
      line = Protocol.encode(1, "scroll", %{scroll_direction: "up", scroll_amount: 3})

      assert Jason.decode!(line) == %{
               "id" => 1,
               "op" => "scroll",
               "scroll_direction" => "up",
               "scroll_amount" => 3
             }
    end
  end

  describe "decode_response/1" do
    test "success carries the result map" do
      assert Protocol.decode_response(~s({"id":3,"result":{"x":1.5,"y":2.0}})) ==
               {:ok, 3, {:ok, %{"x" => 1.5, "y" => 2.0}}}
    end

    test "error carries the message" do
      assert Protocol.decode_response(~s({"id":4,"error":"key: unknown key q"})) ==
               {:ok, 4, {:error, "key: unknown key q"}}
    end

    test "error with null id (parse failure on the helper side)" do
      assert Protocol.decode_response(~s({"id":null,"error":"invalid_json"})) ==
               {:ok, nil, {:error, "invalid_json"}}
    end

    test "invalid JSON is tagged" do
      assert Protocol.decode_response("{not json") == {:error, :invalid_json}
    end

    test "unrecognised JSON shape is malformed" do
      assert {:error, {:malformed, %{"id" => 1}}} =
               Protocol.decode_response(~s({"id":1,"nonsense":true}))
    end
  end

  describe "parse_chord/1 — valid" do
    test "modifiers normalize and order canonically" do
      assert Protocol.parse_chord("shift+cmd+s") ==
               {:ok, %{modifiers: ["command", "shift"], key: "s"}}
    end

    test "aliases map to canonical names" do
      assert Protocol.parse_chord("ctrl+alt+opt+delete") ==
               {:ok, %{modifiers: ["control", "option"], key: "delete"}}
    end

    test "bare key has no modifiers and preserves case" do
      assert Protocol.parse_chord("Return") == {:ok, %{modifiers: [], key: "Return"}}
    end

    test "the literal + key" do
      assert Protocol.parse_chord("cmd++") == {:ok, %{modifiers: ["command"], key: "+"}}
    end

    test "duplicate modifiers dedupe" do
      assert Protocol.parse_chord("cmd+cmd+a") ==
               {:ok, %{modifiers: ["command"], key: "a"}}
    end
  end

  describe "parse_chord/1 — invalid" do
    test "unknown modifier" do
      assert Protocol.parse_chord("hyper+s") == {:error, {:unknown_modifier, "hyper"}}
    end

    test "empty string" do
      assert Protocol.parse_chord("") == {:error, :empty_key}
    end
  end
end
