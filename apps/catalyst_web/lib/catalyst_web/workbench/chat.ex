defmodule CatalystWeb.Workbench.Chat do
  @moduledoc """
  Pure chat workbench driven exclusively through host-interpreted session effects.

  The implementation owns serializable presentation state. The stable Workbench
  host owns session processes, PubSub subscriptions, model selection, and all
  calls into `Catalyst.Session`.
  """

  @behaviour Catalyst.Contracts.Workbench.V1

  @open_request "session-open"
  @submit_request "session-submit"
  @abort_request "session-abort"
  @snapshot_request "session-snapshot"
  @models_request "models-list"
  @threads_request "session-list"
  @attach_request "session-attach"
  @close_request "session-close"
  @configure_request "session-configure"

  @impl true
  def mount(%{workspace: workspace}) when is_binary(workspace) do
    {:ok,
     %{
       version: 1,
       workspace: workspace,
       session_id: nil,
       messages: [],
       input: "",
       models: [],
       selected_model: nil,
       threads: %{projects: []},
       file_search: nil,
       file_search_request: nil,
       file_refs: %{},
       request_seq: 0,
       running: false,
       status: :starting,
       error: nil
     }, [{:models, :list, @models_request}, {:session, :open, @open_request}]}
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

        {:ok,
         %{
           state
           | input: "",
             running: true,
             error: nil,
             file_search: nil,
             file_refs: %{}
         }, [{:session, :submit, @submit_request, session_id, prompt}]}

      _unavailable ->
        {:ok, %{state | error: "The chat session is not ready yet."}, []}
    end
  end

  def event("chat:abort", _params, %{session_id: session_id} = state, _context)
      when is_binary(session_id) do
    {:ok, state, [{:session, :abort, @abort_request, session_id}]}
  end

  def event("chat:new", _params, state, _context) do
    {:ok, %{state | session_id: nil, messages: [], running: false, status: :starting},
     [{:session, :open, @open_request, selected_settings(state)}]}
  end

  def event("chat:model", %{"model" => %{"selection" => selection}}, state, _context) do
    with {:ok, selected} <- parse_selection(selection),
         session_id when is_binary(session_id) <- state.session_id do
      {:ok, %{state | selected_model: selected, error: nil},
       [
         {:session, :configure, @configure_request, session_id,
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
      true -> {:ok, state, []}
      false -> {:ok, %{state | status: :starting}, [{:session, :attach, @attach_request, id}]}
    end
  end

  def event("chat:close", %{"id" => id}, state, _context) when is_binary(id) do
    effects =
      case id == state.session_id do
        true ->
          [
            {:session, :close, @close_request, id},
            {:session, :open, @open_request, selected_settings(state)}
          ]

        false ->
          [
            {:session, :close, @close_request, id},
            {:session, :list, @threads_request, state.session_id}
          ]
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
  def info({:effect_result, @open_request, {:ok, snapshot}}, state, _context),
    do: apply_snapshot(state, snapshot)

  def info({:effect_result, @attach_request, {:ok, snapshot}}, state, _context),
    do: apply_snapshot(state, snapshot)

  def info({:effect_result, @submit_request, {:ok, result}}, state, _context) do
    next_state =
      state
      |> Map.put(:running, true)
      |> Map.put(:error, nil)
      |> maybe_put_threads(result)

    {:ok, next_state, []}
  end

  def info({:effect_result, @abort_request, :ok}, state, _context),
    do: {:ok, %{state | running: false}, []}

  def info({:effect_result, @snapshot_request, {:ok, snapshot}}, state, _context),
    do: apply_snapshot(state, snapshot)

  def info({:effect_result, @models_request, {:ok, models}}, state, _context)
      when is_list(models) do
    {:ok, %{state | models: models}, []}
  end

  def info({:effect_result, @threads_request, {:ok, threads}}, state, _context)
      when is_map(threads) do
    {:ok, %{state | threads: threads}, []}
  end

  def info({:effect_result, @close_request, :ok}, state, _context), do: {:ok, state, []}

  def info({:effect_result, @configure_request, {:ok, snapshot}}, state, _context),
    do: apply_snapshot(state, snapshot)

  def info(
        {:effect_result, request_id, {:ok, %{query: query, results: results}}},
        %{file_search_request: request_id} = state,
        _context
      )
      when is_binary(request_id) and is_binary(query) and is_list(results) do
    {:ok, %{state | file_search: %{query: query, results: results}}, []}
  end

  def info({:effect_result, _request_id, {:error, reason}}, state, _context),
    do: {:ok, %{state | running: false, status: :error, error: inspect(reason)}, []}

  def info({:session_event, session_id, _event}, %{session_id: session_id} = state, _context),
    do: {:ok, state, [{:session, :snapshot, @snapshot_request, session_id}]}

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

    case Map.get(restored, :session_id) do
      session_id when is_binary(session_id) ->
        {:ok, restored,
         [
           {:models, :list, @models_request},
           {:session, :snapshot, @snapshot_request, session_id}
         ]}

      _missing ->
        {:ok, Map.put(restored, :session_id, nil),
         [
           {:models, :list, @models_request},
           {:session, :open, @open_request, selected_settings(restored)}
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
        sequence = state.request_seq + 1
        request_id = "file-search-#{sequence}"

        {:ok, %{state | request_seq: sequence, file_search_request: request_id},
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
end
