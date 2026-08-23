defmodule CatalystWeb.Workbench.ChatTest do
  use ExUnit.Case, async: true

  alias CatalystWeb.Workbench.Chat

  @context %{workspace: "/workspace"}

  test "mount requests the model catalog and a host-owned session" do
    assert {:ok, state, effects} = Chat.mount(@context)

    assert state.status == :starting
    assert state.workspace == "/workspace"
    assert effects == [{:models, :list, "models-list"}, {:session, :open, "session-open"}]
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

    assert effect ==
             {:session, :configure, "session-configure", "session-one",
              %{"provider" => "provider-one", "model" => "model-one"}}

    assert {:ok, switching, [{:session, :attach, "session-attach", "session-two"}]} =
             Chat.event("chat:switch", %{"id" => "session-two"}, selected, @context)

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

    assert {:ok, submitted, [{:session, :submit, "session-submit", "session-one", prompt}]} =
             Chat.event(
               "chat:submit",
               %{
                 "chat" => %{"message" => picked.input},
                 "attachments" => [image]
               },
               picked,
               @context
             )

    assert prompt == %{"text" => "Review lib/server.ex", "images" => [image]}
    assert submitted.input == ""
    assert submitted.running
    assert submitted.file_refs == %{}
  end

  defp ready_state do
    {:ok, state, _effects} = Chat.mount(@context)

    snapshot = %{
      session_id: "session-one",
      workspace: "/workspace",
      messages: [],
      running: false,
      error: nil,
      selected_model: nil,
      threads: %{projects: []}
    }

    {:ok, state, []} =
      Chat.info({:effect_result, "session-open", {:ok, snapshot}}, state, @context)

    state
  end
end
