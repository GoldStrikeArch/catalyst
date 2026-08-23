defmodule Catalyst.Session.EngineState do
  @moduledoc """
  Stable state projection owned by a version-one session engine.

  The session host keeps process, persistence, and configuration fields outside
  this struct. Projection and merge copy only map references, so transcripts are
  not duplicated for each event.
  """

  alias Catalyst.{Message, Model}

  @state_fields [
    :model,
    :messages,
    :streaming_message,
    :streaming_text,
    :streaming_thinking,
    :pending_tool_calls,
    :error_message,
    :in_flight,
    :current_run_metadata,
    :run_final_assistant,
    :steering,
    :follow_up
  ]

  @type t :: %__MODULE__{
          schema_version: 1,
          model: Model.t() | nil,
          messages: [Message.t()],
          streaming_message: Message.Assistant.t() | nil,
          streaming_text: iodata(),
          streaming_thinking: iodata(),
          pending_tool_calls: MapSet.t(String.t()),
          error_message: String.t() | nil,
          in_flight: [term()],
          current_run_metadata: map() | nil,
          run_final_assistant: Message.Assistant.t() | nil,
          steering: :queue.queue(Message.User.t()),
          follow_up: :queue.queue(Message.User.t())
        }

  defstruct schema_version: 1,
            model: nil,
            messages: [],
            streaming_message: nil,
            streaming_text: [],
            streaming_thinking: [],
            pending_tool_calls: MapSet.new(),
            error_message: nil,
            in_flight: [],
            current_run_metadata: nil,
            run_final_assistant: nil,
            steering: :queue.new(),
            follow_up: :queue.new()

  @doc "Project engine-owned fields from the session host state."
  @spec from_server(map()) :: t()
  def from_server(state) when is_map(state) do
    struct!(__MODULE__, Map.take(state, @state_fields))
  end

  @doc "Merge engine-owned fields back into the session host state."
  @spec merge_into_server(map(), t()) :: map()
  def merge_into_server(state, %__MODULE__{} = engine_state) when is_map(state) do
    Map.merge(state, Map.take(engine_state, @state_fields))
  end
end
