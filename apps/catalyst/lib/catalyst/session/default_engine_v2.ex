defmodule Catalyst.Session.DefaultEngineV2 do
  @moduledoc """
  Built-in pure session state machine for `catalyst.session-engine/2`.

  It preserves the existing queue and reducer behavior while returning host
  actions as validated `Catalyst.Session.Effect` values.
  """

  @behaviour Catalyst.Contracts.SessionEngine.V2

  alias Catalyst.Session.{Effect, EngineState, Reducer, StateCapsule}

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def command({:prompt, message, :idle}, state, private),
    do: {:ok, state, private, [Effect.start_run([message])], :ok}

  def command({:prompt, _message, :busy}, _state, _private), do: {:error, :busy}

  def command({:submit, message, :idle}, state, private),
    do: {:ok, state, private, [Effect.start_run([message])], {:ok, :started}}

  def command({:submit, message, :busy}, state, private) do
    state = %{state | follow_up: :queue.in(message, state.follow_up)}
    {:ok, state, private, [], {:ok, :queued}}
  end

  def command({:enqueue, kind, message}, state, private)
      when kind in [:steering, :follow_up] do
    queue = :queue.in(message, Map.fetch!(state, kind))
    {:ok, Map.replace!(state, kind, queue), private, [], :ok}
  end

  def command({:drain, kind}, state, private) when kind in [:steering, :follow_up] do
    messages = state |> Map.fetch!(kind) |> :queue.to_list()
    in_flight = state.in_flight ++ Enum.map(messages, &{kind, &1})

    state =
      state
      |> Map.replace!(kind, :queue.new())
      |> Map.replace!(:in_flight, in_flight)

    {:ok, state, private, [], messages}
  end

  def command(:reset, state, private) do
    state = %{
      state
      | messages: [],
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
    }

    {:ok, state, private, [Effect.stop_run(:reset)], :ok}
  end

  def command(command, _state, _private),
    do: {:error, {:unsupported_session_command, command}}

  @impl true
  def event(envelope, state, private),
    do: {:ok, Reducer.reduce(envelope.event, state), private, []}

  @impl true
  def aborted_tool_results(state, _private, reason),
    do: Reducer.aborted_tool_results(state, reason)

  @impl true
  def failure_message(state, _private, reason),
    do: Reducer.failure_message(state, reason)

  @impl true
  def state_version, do: 1

  @impl true
  def snapshot(%EngineState{} = state, private),
    do: {:ok, %{semantic_state: state, private_state: private}}

  @impl true
  def restore(%StateCapsule{
        payload: %{semantic_state: %EngineState{} = state, private_state: private}
      }),
      do: {:ok, state, private}

  def restore(%StateCapsule{payload: %EngineState{} = state}), do: {:ok, state, %{}}
  def restore(%StateCapsule{}), do: {:error, :invalid_default_engine_capsule}

  @impl true
  def verify_handoff(%StateCapsule{} = capsule, %EngineState{}, _private),
    do: StateCapsule.verify(capsule)
end
