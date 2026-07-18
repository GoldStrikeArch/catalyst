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

    assert state.streaming_text == ["lo", "hel"]
    assert state.streaming_thinking == ["hm"]

    assert [%Content.Thinking{thinking: "hm"}, %Content.Text{text: "hello"}] =
             snapshot.streaming_message.content

    # The final MessageEnd clears the accumulation.
    done = Reducer.reduce(%Event.MessageEnd{message: a}, state)
    assert done.streaming_text == []
    assert done.streaming_thinking == []
  end

  test "snapshot accepts the pre-upgrade nested iodata accumulator", %{state: state} do
    assistant = %Message.Assistant{content: [], timestamp: Message.now()}

    legacy = %{
      state
      | streaming_message: assistant,
        streaming_text: [[[] | "hel"] | "lo"],
        streaming_thinking: []
    }

    assert [%Content.Text{text: "hello"}] =
             Catalyst.Session.Snapshot.of(legacy).streaming_message.content

    migrated =
      Reducer.reduce(
        %Event.MessageUpdate{llm_event: %Catalyst.LLM.Event.TextDelta{delta: "!"}},
        legacy
      )

    assert migrated.streaming_text == ["!", "hello"]

    assert [%Content.Text{text: "hello!"}] =
             Catalyst.Session.Snapshot.of(migrated).streaming_message.content
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

  test "ContextStatus updates only active run metadata and remains non-persistent", %{
    state: state
  } do
    status = %Event.ContextStatus{
      used_tokens: 123,
      threshold: 456,
      threshold_source: :builtin,
      anchored: true,
      estimate_source: :provider,
      context_digest: String.duplicate("a", 64)
    }

    assert Reducer.reduce(status, state) == state

    active = %{state | current_run_metadata: %{prompt: %{digest: "prompt"}}}
    reduced = Reducer.reduce(status, active)

    assert reduced.current_run_metadata.context_status == Map.from_struct(status)
    assert reduced.messages == active.messages
    assert Store.load(state.store.path) == []
  end

  test "ContextCompacted replaces only messages and keeps active run fields", %{state: state} do
    replacement = [Message.user("summary"), Message.user("current")]

    state = %{
      state
      | messages: [Message.user("old")],
        steering: :queue.in(Message.user("steer"), :queue.new()),
        follow_up: :queue.in(Message.user("later"), :queue.new()),
        in_flight: [{:steering, Message.user("active")}],
        pending_tool_calls: MapSet.new(["call"]),
        streaming_message: %Message.Assistant{}
    }

    reduced =
      Reducer.reduce(%Event.ContextCompacted{replacement: replacement}, state)

    assert reduced.messages == Enum.reverse(replacement)
    assert reduced.steering == state.steering
    assert reduced.follow_up == state.follow_up
    assert reduced.in_flight == state.in_flight
    assert reduced.pending_tool_calls == state.pending_tool_calls
    assert reduced.streaming_message == state.streaming_message
  end

  test "failure_message builds an aborted/error assistant", %{state: state} do
    aborted = Reducer.failure_message(state, :killed)
    assert aborted.stop_reason == :aborted
    assert Content.text_of(aborted.content) == "Run aborted."

    assert Reducer.failure_message(state, :boom).stop_reason == :error
  end
end
