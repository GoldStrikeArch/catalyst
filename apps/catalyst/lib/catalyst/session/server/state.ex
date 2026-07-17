defmodule Catalyst.Session.Server.State do
  @moduledoc false

  defstruct [
    :id,
    :cwd,
    :system_prompt,
    :model,
    :provider,
    :tools,
    :opts,
    :store,
    :run,
    # Supervised provider warmup monitored by the session. It must finish or
    # be killed before terminate drops the connection cache, or a late warmup
    # could repopulate a dead session.
    :prewarm,
    # Ref identifying the CURRENT run; events from killed/finished runs that
    # are still buffered in the mailbox carry a stale ref and are dropped.
    :run_ref,
    # Whether the current run's AgentEnd was folded/broadcast — lets abort
    # tell "run finished cleanly" from "its tail events got dropped".
    agent_ended: false,
    # Transcript, stored NEWEST-FIRST so per-event appends are O(1); reversed
    # at the boundaries (Snapshot.of/1, start_run's loop context).
    messages: [],
    streaming_message: nil,
    # Streamed deltas of the in-flight assistant message, accumulated as
    # iodata so a reattaching UI can rebuild the partial bubble (Snapshot).
    streaming_text: [],
    streaming_thinking: [],
    pending_tool_calls: MapSet.new(),
    error_message: nil,
    steering: :queue.new(),
    follow_up: :queue.new(),
    # Messages handed to the run via drain_steering/drain_follow_up but not
    # yet folded back as MessageEnd events — re-queued if the run dies, so an
    # abort can't swallow a user's steering message. `{:steering | :follow_up, msg}`.
    in_flight: []
  ]
end
