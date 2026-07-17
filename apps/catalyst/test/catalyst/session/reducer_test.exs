defmodule Catalyst.Session.ReducerTest do
  use ExUnit.Case, async: true

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Message, Model}
  alias Catalyst.Session.{Reducer, Server, Store}

  setup do
    tmp = Path.join(System.tmp_dir!(), "reducer_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    state = %Server.State{
      id: "r1",
      cwd: tmp,
      store: Store.new(tmp, id: "r1"),
      model: %Model{id: "faux", api: "faux"}
    }

    {:ok, state: state}
  end

  test "MessageEnd appends (newest-first) and clears streaming for an assistant", %{state: state} do
    state = %{
      state
      | streaming_message: %Message.Assistant{content: [], timestamp: Message.now()}
    }

    msg = %Message.Assistant{
      content: Content.text("hi"),
      stop_reason: :stop,
      timestamp: Message.now()
    }

    state = Reducer.reduce(%Event.MessageEnd{message: msg}, state)

    assert state.messages == [msg]
    assert state.streaming_message == nil
    # Persistence is the server's job now — the fold itself writes nothing.
    assert Store.load(state.store.path) == []
  end

  test "MessageEnd prepends so per-event appends stay O(1)", %{state: state} do
    first = Message.user("one")
    second = Message.user("two")

    state = Reducer.reduce(%Event.MessageEnd{message: first}, state)
    state = Reducer.reduce(%Event.MessageEnd{message: second}, state)

    assert state.messages == [second, first]
  end

  test "MessageStart sets the streaming message", %{state: state} do
    a = %Message.Assistant{content: [], timestamp: Message.now()}
    assert Reducer.reduce(%Event.MessageStart{message: a}, state).streaming_message == a
  end

  test "streamed deltas accumulate and surface in the snapshot's streaming message", %{
    state: state
  } do
    a = %Message.Assistant{content: [], timestamp: Message.now()}

    state =
      [
        %Event.MessageStart{message: a},
        %Event.MessageUpdate{llm_event: %Catalyst.LLM.Event.ThinkingDelta{delta: "hm"}},
        %Event.MessageUpdate{llm_event: %Catalyst.LLM.Event.TextDelta{delta: "hel"}},
        %Event.MessageUpdate{llm_event: %Catalyst.LLM.Event.TextDelta{delta: "lo"}}
      ]
      |> Enum.reduce(state, &Reducer.reduce/2)

    snapshot = Catalyst.Session.Snapshot.of(state)

    assert [%Content.Thinking{thinking: "hm"}, %Content.Text{text: "hello"}] =
             snapshot.streaming_message.content

    # The final MessageEnd clears the accumulation.
    done = Reducer.reduce(%Event.MessageEnd{message: a}, state)
    assert done.streaming_text == []
    assert done.streaming_thinking == []
  end

  test "a provider-error assistant surfaces in error_message", %{state: state} do
    err = %Message.Assistant{
      content: Content.text("provider error"),
      stop_reason: :error,
      error_message: "boom",
      timestamp: Message.now()
    }

    assert Reducer.reduce(%Event.MessageEnd{message: err}, state).error_message == "boom"
  end

  test "MessageEnd reconciles in-flight steering; AgentEnd clears the rest", %{state: state} do
    steer = Message.user("steer me")
    state = %{state | in_flight: [{:steering, steer}, {:follow_up, Message.user("later")}]}

    state = Reducer.reduce(%Event.MessageEnd{message: steer}, state)
    assert [{:follow_up, _}] = state.in_flight

    assert Reducer.reduce(%Event.AgentEnd{messages: []}, state).in_flight == []
  end

  test "tool start/end track pending calls", %{state: state} do
    state = Reducer.reduce(%Event.ToolExecutionStart{call_id: "c1"}, state)
    assert MapSet.member?(state.pending_tool_calls, "c1")

    state = Reducer.reduce(%Event.ToolExecutionEnd{call_id: "c1"}, state)
    refute MapSet.member?(state.pending_tool_calls, "c1")
  end

  test "failure_message builds an aborted/error assistant", %{state: state} do
    aborted = Reducer.failure_message(state, :killed)
    assert aborted.stop_reason == :aborted
    assert Content.text_of(aborted.content) == "Run aborted."

    assert Reducer.failure_message(state, :boom).stop_reason == :error
  end
end
