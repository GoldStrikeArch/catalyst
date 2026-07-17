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

  test "MessageEnd appends, persists, and clears streaming for an assistant", %{state: state} do
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
    assert length(Store.load(state.store.path)) == 1
  end

  test "MessageStart sets the streaming message", %{state: state} do
    a = %Message.Assistant{content: [], timestamp: Message.now()}
    assert Reducer.reduce(%Event.MessageStart{message: a}, state).streaming_message == a
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
