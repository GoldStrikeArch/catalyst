defmodule CatalystWeb.Workbench.IDE do
  @moduledoc "A minimal pure IDE workbench backed by host-interpreted effects."

  @behaviour Catalyst.Contracts.Workbench.V1

  @impl true
  def mount(%{workspace: workspace}) do
    {:ok,
     %{
       version: 1,
       workspace: workspace,
       files: [],
       active_file: nil,
       editor_content: "",
       editor_dirty: false,
       command: "",
       output: "Ready.",
       palette_open: false,
       busy: %{"files" => true}
     }, [{:workspace, :list, "files"}]}
  end

  def mount(context), do: {:error, {:invalid_workbench_context, context}}

  @impl true
  def event("ide:open", %{"path" => path}, state, _context) when is_binary(path) do
    start(state, "read", [{:workspace, :read, "read", path}])
  end

  def event("ide:editor", %{"editor" => %{"content" => content}}, state, _context)
      when is_binary(content) do
    {:ok, %{state | editor_content: content, editor_dirty: true}, []}
  end

  def event("ide:save", params, state, _context) do
    content = get_in(params, ["editor", "content"]) || state.editor_content

    case {state.active_file, content} do
      {path, content} when is_binary(path) and is_binary(content) ->
        state = %{state | editor_content: content}
        start(state, "save", [{:workspace, :write, "save", path, content}])

      _missing ->
        {:ok, %{state | output: "Open a file before saving."}, []}
    end
  end

  def event("ide:run", %{"terminal" => %{"command" => command}}, state, _context)
      when is_binary(command) do
    command = String.trim(command)

    case command do
      "" ->
        {:ok, %{state | output: "Enter a command first."}, []}

      command ->
        start(%{state | command: command}, "command", [{:command, :run, "command", command}])
    end
  end

  def event("ide:refresh", _params, state, _context),
    do: start(state, "files", [{:workspace, :list, "files"}])

  def event("ide:palette-toggle", _params, state, _context),
    do: {:ok, %{state | palette_open: not state.palette_open}, []}

  def event("ide:palette", %{"action" => "chat"}, state, _context),
    do: {:ok, close_palette(state), [{:navigate, "/"}]}

  def event("ide:palette", %{"action" => "refresh"}, state, _context),
    do: start(close_palette(state), "files", [{:workspace, :list, "files"}])

  def event("ide:palette", %{"action" => "save"}, state, context),
    do: event("ide:save", %{}, close_palette(state), context)

  def event("ide:palette", %{"action" => "clear"}, state, _context),
    do: {:ok, %{close_palette(state) | output: ""}, []}

  def event(_event, _params, state, _context), do: {:ok, state, []}

  @impl true
  def info({:effect_result, "files", {:ok, files}}, state, _context) when is_list(files) do
    {:ok, state |> finish("files") |> Map.put(:files, files), []}
  end

  def info({:effect_result, "read", {:ok, %{path: path, content: content}}}, state, _context) do
    {:ok,
     state
     |> finish("read")
     |> Map.merge(%{
       active_file: path,
       editor_content: content,
       editor_dirty: false,
       output: "Opened #{path}."
     }), []}
  end

  def info({:effect_result, "save", :ok}, state, _context) do
    {:ok,
     state
     |> finish("save")
     |> Map.merge(%{editor_dirty: false, output: "Saved #{state.active_file}."}), []}
  end

  def info({:effect_result, "command", {:ok, result}}, state, _context) when is_map(result) do
    output = command_output(state.command, result)
    {:ok, state |> finish("command") |> Map.put(:output, output), []}
  end

  def info({:effect_result, request_id, {:error, reason}}, state, _context)
      when is_binary(request_id) do
    {:ok,
     state
     |> finish(request_id)
     |> Map.put(:output, "#{request_id} failed: #{inspect(reason)}"), []}
  end

  def info(_message, state, _context), do: {:ok, state, []}

  @impl true
  def render_target(_state), do: "ide"

  @impl true
  def forms(state) do
    %{
      editor: %{"content" => state.editor_content},
      terminal: %{"command" => state.command}
    }
  end

  defp start(state, request_id, effects) do
    case Map.get(state.busy, request_id, false) do
      true -> {:ok, state, []}
      false -> {:ok, put_in(state.busy[request_id], true), effects}
    end
  end

  defp finish(state, request_id), do: update_in(state.busy, &Map.delete(&1, request_id))
  defp close_palette(state), do: %{state | palette_open: false}

  defp command_output(command, result) do
    status = Map.get(result, :status, "?")
    output = Map.get(result, :out, "")
    capped = if Map.get(result, :truncated, false), do: "\n[output capped]", else: ""
    "$ #{command}\n#{output}#{capped}\n[exit #{status}]"
  end
end
