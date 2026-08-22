defmodule Catalyst.Session.Store.EventEnvelopeCodecTest do
  use ExUnit.Case, async: true

  alias Catalyst.Agent.Event
  alias Catalyst.Runtime.ContractRef
  alias Catalyst.Session.EventEnvelope
  alias Catalyst.Session.Store.EventEnvelopeCodec
  alias Catalyst.{Content, Message}

  test "durable envelope metadata and payload encode without inventing absent identity" do
    envelope =
      EventEnvelope.new(%Event.MessageEnd{message: Message.user("hello")}, "session-1",
        event_id: "event-1",
        correlation_id: "run-1",
        producer_contract: ContractRef.new!("catalyst.agent-run-engine", 1)
      )

    assert {:ok, entry} = EventEnvelopeCodec.encode(envelope)
    persisted = entry["envelope"]

    assert persisted["eventId"] == "event-1"
    assert persisted["sessionId"] == "session-1"
    assert persisted["correlationId"] == "run-1"
    refute Map.has_key?(persisted, "causationId")

    assert persisted["producerContract"] == %{
             "id" => "catalyst.agent-run-engine",
             "version" => 1
           }

    assert %{"type" => "message"} = persisted["payload"]

    assert {:ok, decoded} = EventEnvelopeCodec.decode(entry)
    assert decoded.event_id == envelope.event_id
    assert decoded.correlation_id == envelope.correlation_id
    assert decoded.producer_contract == envelope.producer_contract
    assert %{"type" => "message", "message" => encoded_message} = decoded.event
    assert {:ok, message} = Catalyst.Session.Store.decode(encoded_message)
    assert Content.text_of(message.content) == "hello"
  end

  test "corrupt and forward-versioned envelopes return tagged errors" do
    valid = %{
      "type" => "event",
      "envelope" => %{
        "version" => 1,
        "eventId" => "event-1",
        "sessionId" => "session-1",
        "payloadSchemaVersion" => 1,
        "payload" => %{"type" => "reset"}
      }
    }

    assert {:error, {:unsupported_event_envelope_version, 2}} =
             valid
             |> put_in(["envelope", "version"], 2)
             |> EventEnvelopeCodec.decode()

    assert {:error, {:unsupported_event_payload_schema, 2}} =
             valid
             |> put_in(["envelope", "payloadSchemaVersion"], 2)
             |> EventEnvelopeCodec.decode()

    assert {:error, {:invalid_event_envelope_field, "eventId", nil}} =
             valid
             |> update_in(["envelope"], &Map.delete(&1, "eventId"))
             |> EventEnvelopeCodec.decode()

    assert {:error, {:invalid_event_producer_contract, "broken"}} =
             valid
             |> put_in(["envelope", "producerContract"], "broken")
             |> EventEnvelopeCodec.decode()

    assert {:error, {:invalid_event_payload, %{"type" => "unknown"}}} =
             valid
             |> put_in(["envelope", "payload"], %{"type" => "unknown"})
             |> EventEnvelopeCodec.decode()

    assert {:error, {:invalid_event_payload, %{"type" => "message"}}} =
             valid
             |> put_in(["envelope", "payload"], %{"type" => "message"})
             |> EventEnvelopeCodec.decode()
  end
end
