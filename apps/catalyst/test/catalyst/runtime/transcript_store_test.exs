defmodule Catalyst.Runtime.TranscriptStoreTest do
  use ExUnit.Case, async: false

  alias Catalyst.Runtime.TranscriptStore

  test "the JSONL backend is an ordinary session-bound claim" do
    assert {:ok, resolution} = TranscriptStore.resolve(session_id: "session-1")

    assert resolution.claim.owner == :builtin
    assert resolution.claim.implementation == Catalyst.Session.JSONLTranscriptStore
    assert resolution.claim.binding == {:pin, :session}

    assert TranscriptStore.metadata(resolution) == %{
             service: "agent.transcript_store/default",
             contract: %{id: "catalyst.transcript-store", version: 1},
             snapshot_id: resolution.snapshot_id,
             owner: :builtin,
             scope: %{},
             binding: {:pin, :session},
             provenance: :builtin,
             implementation: Catalyst.Session.JSONLTranscriptStore,
             handle_version: 1
           }
  end
end
