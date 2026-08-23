defmodule CatalystWeb.Workbench.Chat do
  @moduledoc """
  Pure chat workbench driven exclusively through host-interpreted session effects.

  The implementation owns serializable presentation state. The stable Workbench
  host owns session processes, PubSub subscriptions, model selection, and all
  calls into `Catalyst.Session`.
  """

  @behaviour Catalyst.Contracts.Workbench.V1

  alias Catalyst.Agent.Event
  alias Catalyst.LLM.Event, as: LLMEvent

  @impl true
  def mount(%{workspace: workspace}) when is_binary(workspace) do
    state = %{
      version: 1,
      workspace: workspace,
      session_id: nil,
      messages: [],
      messages_truncated: 0,
      input: "",
      models: [],
      selected_model: nil,
      threads: %{projects: []},
      file_search: nil,
      file_search_request: nil,
      file_refs: %{},
      pending_requests: %{},
      request_seq: 0,
      running: false,
      status: :starting,
      error: nil
    }

    {state, models_request} = request(state, "models")
    {state, open_request} = request(state, "open")

    {:ok, state, [{:models, :list, models_request}, {:session, :open, open_request}]}
  end

  def mount(context), do: {:error, {:invalid_workbench_context, context}}

  @impl true
  def event("chat:change", %{"chat" => %{"message" => input}}, state, _context)
      when is_binary(input) do
    search_files(%{state | input: input}, input)
  end

  def event("chat:submit", params, state, _context) do
    input =
      params
      |> get_in(["chat", "message"])
      |> fallback_input(state)
      |> expand_refs(state.file_refs)
      |> String.trim()

    images = Map.get(params, "attachments", [])

    case {state.session_id, input, images} do
      {_session_id, "", []} ->
        {:ok, state, []}

      {session_id, input, images} when is_binary(session_id) and is_list(images) ->
        prompt = %{"text" => input, "images" => images}
        {state, request_id} = request(state, "submit")

        {:ok,
         %{
           state
           | input: "",
             running: true,
             error: nil,
             file_search: nil,
             file_refs: %{}
         }, [{:session, :submit, request_id, session_id, prompt}]}

      _unavailable ->
        {:ok, %{state | error: "The chat session is not ready yet."}, []}
    end
  end

  def event("chat:abort", _params, %{session_id: session_id} = state, _context)
      when is_binary(session_id) do
    {state, request_id} = request(state, "abort")
    {:ok, state, [{:session, :abort, request_id, session_id}]}
  end

  def event("chat:new", _params, state, _context) do
    {state, request_id} = request(state, "open")

    {:ok, %{state | session_id: nil, messages: [], running: false, status: :starting},
     [{:session, :open, request_id, selected_settings(state)}]}
  end

  def event("chat:model", %{"model" => %{"selection" => selection}}, state, _context) do
    with {:ok, selected} <- parse_selection(selection),
         session_id when is_binary(session_id) <- state.session_id do
      {state, request_id} = request(state, "configure")

      {:ok, %{state | selected_model: selected, error: nil},
       [
         {:session, :configure, request_id, session_id,
          %{
            "provider" => selected.provider,
            "model" => selected.model
          }}
       ]}
    else
      _invalid -> {:ok, %{state | error: "That model selection is unavailable."}, []}
    end
  end

  def event("chat:switch", %{"id" => id}, state, _context) when is_binary(id) do
    case id == state.session_id do
      true ->
        {:ok, state, []}

      false ->
        {state, request_id} = request(state, "attach")
        {:ok, %{state | status: :starting}, [{:session, :attach, request_id, id}]}
    end
  end

  def event("chat:close", %{"id" => id}, state, _context) when is_binary(id) do
    {state, close_request} = request(state, "close")

    {state, effects} =
      case id == state.session_id do
        true ->
          {state, open_request} = request(state, "open")

          {state,
           [
             {:session, :close, close_request, id},
             {:session, :open, open_request, selected_settings(state)}
           ]}

        false ->
          {state, threads_request} = request(state, "threads")

          {state,
           [
             {:session, :close, close_request, id},
             {:session, :list, threads_request, state.session_id}
           ]}
      end

    {:ok, state, effects}
  end

  def event(
        "chat:pick-file",
        %{"label" => label, "path" => path},
        state,
        _context
      )
      when is_binary(label) and is_binary(path) do
    input = Regex.replace(~r/@\S*$/, state.input, fn _match -> label <> " " end)

    {:ok,
     %{
       state
       | input: input,
         file_search: nil,
         file_search_request: nil,
         file_refs: Map.put(state.file_refs, label, path)
     }, []}
  end

  def event(_event, _params, state, _context), do: {:ok, state, []}

  @impl true
  def info({:effect_result, request_id, result}, state, _context) when is_binary(request_id) do
    case pop_request(state, request_id) do
      {:ok, operation, state} -> handle_effect_result(operation, request_id, result, state)
      :error -> {:ok, state, []}
    end
  end

  def info(
        {:session_event, session_id, %Event.MessageStart{}},
        %{session_id: session_id} = state,
        _context
      ),
      do: {:ok, state, [{:client, :push, "workbench:stream_reset", %{}}]}

  def info(
        {:session_event, session_id,
         %Event.MessageUpdate{llm_event: %LLMEvent.TextDelta{delta: delta}}},
        %{session_id: session_id} = state,
        _context
      )
      when is_binary(delta),
      do:
        {:ok, state, [{:client, :push, "workbench:stream_delta", %{kind: "text", delta: delta}}]}

  def info(
        {:session_event, session_id,
         %Event.MessageUpdate{llm_event: %LLMEvent.ThinkingDelta{delta: delta}}},
        %{session_id: session_id} = state,
        _context
      )
      when is_binary(delta),
      do:
        {:ok, state,
         [{:client, :push, "workbench:stream_delta", %{kind: "thinking", delta: delta}}]}

  def info(
        {:session_event, session_id, event},
        %{session_id: session_id} = state,
        _context
      )
      when is_struct(event, Event.MessageEnd) or is_struct(event, Event.ToolExecutionEnd) or
             is_struct(event, Event.AgentEnd),
      do:
        request_snapshot(state, session_id, [
          {:client, :push, "workbench:stream_finish", %{}}
        ])

  def info({:session_event, session_id, _event}, %{session_id: session_id} = state, _context),
    do: {:ok, state, []}

  def info({:session_exit, session_id, reason}, %{session_id: session_id} = state, _context) do
    {:ok, %{state | running: false, status: :error, error: "Session exited: #{inspect(reason)}"},
     []}
  end

  def info(_message, state, _context), do: {:ok, state, []}

  @impl true
  def render_target(_state), do: {__MODULE__, :render}

  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns), do: CatalystWeb.Workbench.ChatView.render(assigns)

  @impl true
  def forms(state) do
    %{
      chat: %{"message" => state.input},
      model: %{"selection" => selection_value(state.selected_model)}
    }
  end

  @impl true
  def snapshot(state), do: {:ok, %{version: 1, payload: state}}

  @impl true
  def restore(%{version: 1, payload: state}, %{workspace: workspace}) when is_map(state) do
    restored =
      state
      |> Map.put(:workspace, workspace)
      |> Map.put(:running, false)
      |> Map.put(:status, :starting)
      |> Map.put(:file_search, nil)
      |> Map.put(:file_search_request, nil)
      |> Map.put(:pending_requests, %{})
      |> Map.put_new(:request_seq, 0)
      |> Map.put_new(:messages_truncated, 0)

    case Map.get(restored, :session_id) do
      session_id when is_binary(session_id) ->
        {restored, models_request} = request(restored, "models")
        {restored, snapshot_request} = request(restored, "snapshot")

        {:ok, restored,
         [
           {:models, :list, models_request},
           {:session, :snapshot, snapshot_request, session_id}
         ]}

      _missing ->
        restored = Map.put(restored, :session_id, nil)
        {restored, models_request} = request(restored, "models")
        {restored, open_request} = request(restored, "open")

        {:ok, restored,
         [
           {:models, :list, models_request},
           {:session, :open, open_request, selected_settings(restored)}
         ]}
    end
  end

  def restore(capsule, _context), do: {:error, {:unsupported_chat_capsule, capsule}}

  defp fallback_input(nil, state), do: state.input
  defp fallback_input(input, _state), do: input

  defp apply_snapshot(state, snapshot) when is_map(snapshot) do
    {:ok,
     state
     |> Map.merge(
       Map.take(snapshot, [
         :session_id,
         :messages,
         :messages_truncated,
         :running,
         :error,
         :selected_model,
         :threads,
         :workspace
       ])
     )
     |> Map.put(:status, :ready)
     |> Map.put(:error, Map.get(snapshot, :error)), []}
  end

  defp apply_snapshot(state, snapshot),
    do:
      {:ok, %{state | status: :error, error: "Invalid session snapshot: #{inspect(snapshot)}"},
       []}

  defp search_files(state, input) do
    case active_file_query(input) do
      nil ->
        {:ok, %{state | file_search: nil, file_search_request: nil}, []}

      query ->
        {state, request_id} = request(state, "file_search", %{"query" => query})

        {:ok, %{state | file_search_request: request_id},
         [{:workspace, :search, request_id, query}]}
    end
  end

  defp active_file_query(input) do
    case Regex.run(~r/(?:^|\s)@(\S*)$/, input) do
      [_, query] -> query
      _no_match -> nil
    end
  end

  defp expand_refs(input, refs) when refs == %{}, do: input

  defp expand_refs(input, refs) do
    refs
    |> Enum.sort_by(fn {label, _path} -> -byte_size(label) end)
    |> Enum.reduce(input, fn {label, path}, expanded ->
      String.replace(expanded, label, path)
    end)
  end

  defp parse_selection(selection) when is_binary(selection) do
    case String.split(selection, "::", parts: 2) do
      [provider, model] when provider != "" and model != "" ->
        {:ok, %{provider: provider, model: model}}

      _invalid ->
        {:error, :invalid_model_selection}
    end
  end

  defp parse_selection(_selection), do: {:error, :invalid_model_selection}

  defp selection_value(%{provider: provider, model: model}), do: "#{provider}::#{model}"
  defp selection_value(_missing), do: ""

  defp selected_settings(%{selected_model: %{provider: provider, model: model}}),
    do: %{"provider" => provider, "model" => model}

  defp selected_settings(_state), do: %{}

  defp maybe_put_threads(state, %{threads: threads}) when is_map(threads),
    do: %{state | threads: threads}

  defp maybe_put_threads(state, _result), do: state

  defp request_snapshot(state, session_id, preceding_effects) do
    {state, request_id} = request(state, "snapshot")

    {:ok, state, preceding_effects ++ [{:session, :snapshot, request_id, session_id}]}
  end

  defp request(state, kind, metadata \\ %{}) do
    sequence = state.request_seq + 1
    request_id = "#{kind}-#{sequence}"
    operation = Map.put(metadata, "kind", kind)

    state = %{
      state
      | request_seq: sequence,
        pending_requests: Map.put(state.pending_requests, request_id, operation)
    }

    {state, request_id}
  end

  defp pop_request(state, request_id) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, _pending} ->
        :error

      {operation, pending} ->
        {:ok, operation, %{state | pending_requests: pending}}
    end
  end

  defp handle_effect_result(%{"kind" => kind}, request_id, {:error, reason}, state),
    do: handle_effect_error(kind, request_id, reason, state)

  defp handle_effect_result(%{"kind" => kind}, _request_id, {:ok, snapshot}, state)
       when kind in ["open", "attach", "snapshot", "configure"],
       do: apply_snapshot(state, snapshot)

  defp handle_effect_result(%{"kind" => "submit"}, _request_id, {:ok, result}, state) do
    next_state =
      state
      |> Map.put(:running, true)
      |> Map.put(:error, nil)
      |> maybe_put_threads(result)

    {:ok, next_state, []}
  end

  defp handle_effect_result(%{"kind" => "abort"}, _request_id, :ok, state),
    do: {:ok, %{state | running: false}, []}

  defp handle_effect_result(%{"kind" => "models"}, _request_id, {:ok, models}, state)
       when is_list(models),
       do: {:ok, %{state | models: models}, []}

  defp handle_effect_result(%{"kind" => "threads"}, _request_id, {:ok, threads}, state)
       when is_map(threads),
       do: {:ok, %{state | threads: threads}, []}

  defp handle_effect_result(%{"kind" => "close"}, _request_id, :ok, state),
    do: {:ok, state, []}

  defp handle_effect_result(
         %{"kind" => "file_search"},
         request_id,
         {:ok, %{query: query, results: results}},
         %{file_search_request: request_id} = state
       )
       when is_binary(query) and is_list(results),
       do: {:ok, %{state | file_search: %{query: query, results: results}}, []}

  defp handle_effect_result(_operation, _request_id, _result, state),
    do: {:ok, state, []}

  defp handle_effect_error("file_search", request_id, reason, state) do
    state =
      case state.file_search_request == request_id do
        true -> %{state | file_search: nil, file_search_request: nil}
        false -> state
      end

    {:ok, %{state | error: "File search unavailable: #{inspect(reason)}"}, []}
  end

  defp handle_effect_error(kind, _request_id, reason, state)
       when kind in ["models", "threads", "configure", "close"] do
    {:ok, %{state | error: "#{human_operation(kind)} failed: #{inspect(reason)}"}, []}
  end

  defp handle_effect_error(kind, _request_id, reason, state)
       when kind in ["submit", "abort", "snapshot"] do
    {:ok,
     %{
       state
       | running: false,
         status: :ready,
         error: "#{human_operation(kind)} failed: #{inspect(reason)}"
     }, []}
  end

  defp handle_effect_error(kind, _request_id, reason, state)
       when kind in ["open", "attach"] do
    {:ok,
     %{
       state
       | running: false,
         status: :error,
         error: "#{human_operation(kind)} failed: #{inspect(reason)}"
     }, []}
  end

  defp human_operation("models"), do: "Model loading"
  defp human_operation("threads"), do: "Thread loading"
  defp human_operation("configure"), do: "Model configuration"
  defp human_operation("close"), do: "Thread closing"
  defp human_operation("submit"), do: "Message submission"
  defp human_operation("abort"), do: "Run cancellation"
  defp human_operation("snapshot"), do: "Session refresh"
  defp human_operation("open"), do: "Session opening"
  defp human_operation("attach"), do: "Session attachment"
end
