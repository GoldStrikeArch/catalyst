defmodule Catalyst.Session.Store.EventEnvelopeReplayTest do
  use ExUnit.Case, async: true

  alias Catalyst.Agent.Event
  alias Catalyst.Session.{EventEnvelope, Store}
  alias Catalyst.{Content, Message}

  test "legacy records and v1 envelopes replay through identical fold semantics" do
    legacy = new_store("legacy")
    mixed = new_store("mixed")
    settings = settings()
    summary = Message.user("summary")
    current = Message.user("current")
    later = Message.user("later")

    compaction = %Event.ContextCompacted{
      replacement: [summary, current],
      summary: summary,
      replaced_count: 1,
      tokens_before: 1_000,
      tokens_after: 200,
      policy: Catalyst.Context.Window
    }

    assert :ok = Store.append_message(legacy, Message.user("discarded"))
    assert :ok = Store.append_reset(legacy)
    assert :ok = Store.append_settings_snapshot(legacy, settings)
    assert :ok = Store.append_compaction(legacy, compaction)
    assert :ok = Store.append_message(legacy, later)

    assert :ok = Store.append_message(mixed, Message.user("discarded"))
    assert :ok = append(mixed, :reset, "event-reset")
    assert :ok = append(mixed, {:settings_snapshot, settings}, "event-settings")
    assert :ok = append(mixed, compaction, "event-compaction")

    assert :ok =
             append(mixed, %Event.MessageEnd{message: later}, "event-message")

    assert Store.load_state(mixed.path) == Store.load_state(legacy.path)

    assert {:ok, state} = Store.load_state(mixed.path)

    assert Enum.map(state.messages, &Content.text_of(&1.content)) == [
             "summary",
             "current",
             "later"
           ]

    assert state.model == settings.model
    assert state.workflow == "review"
    assert state.system_prompt == "Be terse."
  end

  test "a corrupt v1 envelope is skipped without hiding later valid records" do
    store = new_store("corrupt")

    corrupt = %{
      "type" => "event",
      "envelope" => %{
        "version" => 2,
        "eventId" => "future",
        "sessionId" => store.id,
        "payloadSchemaVersion" => 1,
        "payload" => %{"type" => "reset"}
      }
    }

    File.write!(store.path, Jason.encode!(corrupt) <> "\n", [:append])
    assert :ok = append(store, %Event.MessageEnd{message: Message.user("kept")}, "valid")

    assert [message] = Store.load(store.path)
    assert Content.text_of(message.content) == "kept"
  end

  defp append(store, event, event_id) do
    envelope = EventEnvelope.new(event, store.id, event_id: event_id)
    Store.append_envelope(store, envelope)
  end

  defp new_store(label) do
    id = "event-envelope-#{label}-#{System.unique_integer([:positive])}"
    store = Store.new("/tmp/event-envelope-replay", id: id)
    on_exit(fn -> File.rm_rf!(store.path) end)
    store
  end

  defp settings do
    %{
      model: %Catalyst.Model{id: "m-1", api: "faux", provider: "faux", input: [:text]},
      thinking_level: "high",
      workflow: "review",
      system_prompt: "Be terse."
    }
  end
end
