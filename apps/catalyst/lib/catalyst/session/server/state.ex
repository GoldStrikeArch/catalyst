defmodule Catalyst.Session.Server.State do
  @moduledoc false

  alias Catalyst.{Message, Model}
  alias Catalyst.Runtime.Handle
  alias Catalyst.Session.Store

  @type queued_input :: {:steering | :follow_up, Message.User.t()}
  @type run_resource :: map()

  @type t :: %__MODULE__{
          id: String.t(),
          cwd: String.t(),
          system_prompt: String.t() | nil,
          model: Model.t() | nil,
          provider: module() | String.t() | nil,
          tools: term(),
          opts: keyword(),
          store: Store.handle(),
          session_engine_handle: Handle.t(),
          session_engine_metadata: map(),
          parent_id: String.t() | nil,
          root_session_id: String.t(),
          run: Task.t() | nil,
          prewarm: {pid(), reference()} | nil,
          run_ref: reference() | nil,
          agent_depth: non_neg_integer(),
          current_run_metadata: map() | nil,
          last_successful_run_metadata: map() | nil,
          run_resources: [run_resource()],
          agent_ended: boolean(),
          run_final_assistant: Message.Assistant.t() | nil,
          messages: [Message.t()],
          streaming_message: Message.Assistant.t() | nil,
          streaming_text: iodata(),
          streaming_thinking: iodata(),
          pending_tool_calls: MapSet.t(String.t()),
          error_message: String.t() | nil,
          steering: :queue.queue(Message.User.t()),
          follow_up: :queue.queue(Message.User.t()),
          in_flight: [queued_input()]
        }

  defstruct [
    :id,
    :cwd,
    :system_prompt,
    :model,
    :provider,
    :tools,
    :opts,
    :store,
    :session_engine_handle,
    :session_engine_metadata,
    :parent_id,
    :root_session_id,
    :run,
    # Supervised provider warmup monitored by the session. It must finish or
    # be killed before terminate drops the connection cache, or a late warmup
    # could repopulate a dead session.
    :prewarm,
    # Ref identifying the CURRENT run; events from killed/finished runs that
    # are still buffered in the mailbox carry a stale ref and are dropped.
    :run_ref,
    agent_depth: 0,
    # Worker-resolved diagnostics are run-ref scoped. They are never reused as
    # configuration and are not persisted in the JSONL transcript.
    current_run_metadata: nil,
    last_successful_run_metadata: nil,
    # Exact provider/session pairs allocated by the compactor. Session.Server
    # can clean them even when a brutal task kill skips the worker's after block.
    # Companion ids are unique per attempt, so every resource can be cleaned
    # independently without a cross-run ownership-token protocol.
    run_resources: [],
    # Whether the current run's AgentEnd was folded/broadcast — lets abort
    # tell "run finished cleanly" from "its tail events got dropped".
    agent_ended: false,
    # The last assistant finalized by this run only. Metadata promotion must
    # never mistake an assistant from an older persisted run for this result.
    run_final_assistant: nil,
    # Transcript, stored NEWEST-FIRST so per-event appends are O(1); reversed
    # at the boundaries (Snapshot.of/1, start_run's loop context).
    messages: [],
    streaming_message: nil,
    # Streamed deltas of the in-flight assistant message, accumulated in
    # reverse so every append is O(1). Snapshot restores chronological order.
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
