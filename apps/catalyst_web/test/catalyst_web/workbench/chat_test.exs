defmodule CatalystWeb.Workbench.ChatTest do
  use ExUnit.Case, async: true

  alias CatalystWeb.Workbench.Chat
  alias Catalyst.Agent.Event
  alias Catalyst.LLM.Event, as: LLMEvent

  @context %{workspace: "/workspace"}

  test "mount requests the model catalog and a host-owned session" do
    assert {:ok, state, effects} = Chat.mount(@context)

    assert state.status == :starting
    assert state.workspace == "/workspace"
    assert [{:models, :list, models_request}, {:session, :open, open_request}] = effects
    assert models_request =~ "models-"
    assert open_request =~ "open-"
    refute models_request == open_request
  end

  test "model selection and thread switching remain declarative host effects" do
    state = ready_state()

    assert {:ok, selected, [effect]} =
             Chat.event(
               "chat:model",
               %{"model" => %{"selection" => "provider-one::model-one"}},
               state,
               @context
             )

    assert selected.selected_model == %{provider: "provider-one", model: "model-one"}

    assert {:session, :configure, configure_request, "session-one",
            %{"provider" => "provider-one", "model" => "model-one"}} = effect

    assert configure_request =~ "configure-"

    assert {:ok, switching, [{:session, :attach, attach_request, "session-two"}]} =
             Chat.event("chat:switch", %{"id" => "session-two"}, selected, @context)

    assert attach_request =~ "attach-"
    refute attach_request == configure_request
    assert switching.status == :starting
  end

  test "file search ignores stale results and expands a selected file into the prompt" do
    state = ready_state()

    assert {:ok, searching, [{:workspace, :search, request_id, "serv"}]} =
             Chat.event(
               "chat:change",
               %{"chat" => %{"message" => "Review @serv"}},
               state,
               @context
             )

    assert {:ok, ^searching, []} =
             Chat.info(
               {:effect_result, "stale-search", {:ok, %{query: "old", results: []}}},
               searching,
               @context
             )

    assert {:ok, results, []} =
             Chat.info(
               {:effect_result, request_id,
                {:ok, %{query: "serv", results: [%{label: "@server.ex", path: "lib/server.ex"}]}}},
               searching,
               @context
             )

    assert results.file_search.query == "serv"

    assert {:ok, picked, []} =
             Chat.event(
               "chat:pick-file",
               %{"label" => "@server.ex", "path" => "lib/server.ex"},
               results,
               @context
             )

    image = %{"data" => "image-data", "mime_type" => "image/png"}

    assert {:ok, submitted, [{:session, :submit, submit_request, "session-one", prompt}]} =
             Chat.event(
               "chat:submit",
               %{
                 "chat" => %{"message" => picked.input},
                 "attachments" => [image]
               },
               picked,
               @context
             )

    assert submit_request =~ "submit-"
    assert prompt == %{"text" => "Review lib/server.ex", "images" => [image]}
    assert submitted.input == ""
    assert submitted.running
    assert submitted.file_refs == %{}
  end

  test "new sessions are explicit and every open request has a unique id" do
    state = ready_state()

    assert {:ok, first, [{:session, :open, first_request, %{}}]} =
             Chat.event("chat:new", %{}, state, @context)

    assert {:ok, _second, [{:session, :open, second_request, %{}}]} =
             Chat.event("chat:new", %{}, first, @context)

    refute first_request == second_request
  end

  test "streaming deltas use client pushes and snapshot only at lifecycle boundaries" do
    state = ready_state()

    delta =
      %Event.MessageUpdate{llm_event: %LLMEvent.TextDelta{delta: "next token"}}

    assert {:ok, ^state,
            [
              {:client, :push, "workbench:stream_delta", %{kind: "text", delta: "next token"}}
            ]} =
             Chat.info({:session_event, "session-one", delta}, state, @context)

    assert {:ok, finalizing, effects} =
             Chat.info(
               {:session_event, "session-one", %Event.MessageEnd{message: nil}},
               state,
               @context
             )

    assert [
             {:client, :push, "workbench:stream_finish", %{}},
             {:session, :snapshot, snapshot_request, "session-one"}
           ] = effects

    assert snapshot_request =~ "snapshot-"
    assert Map.has_key?(finalizing.pending_requests, snapshot_request)
  end

  test "background file search errors leave the chat usable" do
    state = ready_state()

    assert {:ok, searching, [{:workspace, :search, request_id, "missing"}]} =
             Chat.event(
               "chat:change",
               %{"chat" => %{"message" => "Review @missing"}},
               state,
               @context
             )

    assert {:ok, recovered, []} =
             Chat.info(
               {:effect_result, request_id, {:error, :search_unavailable}},
               searching,
               @context
             )

    assert recovered.status == :ready
    assert recovered.session_id == "session-one"
    assert recovered.error =~ "File search unavailable"
  end

  defp ready_state do
    {:ok, state, effects} = Chat.mount(@context)
    {:session, :open, open_request} = List.last(effects)

    snapshot = %{
      session_id: "session-one",
      workspace: "/workspace",
      messages: [],
      messages_truncated: 0,
      running: false,
      error: nil,
      selected_model: nil,
      threads: %{projects: []}
    }

    {:ok, state, []} =
      Chat.info({:effect_result, open_request, {:ok, snapshot}}, state, @context)

    state
  end
end
