defmodule Catalyst.Agent.ToolRunner do
  @moduledoc """
  Executes the tool calls in an assistant turn (PI's `executeToolCalls`).

  Runs sequentially when any tool in the batch (or the config) requires it,
  otherwise in parallel; assistant order is preserved in the emitted results. A
  tool that raises/exits becomes an error tool-result rather than crashing the
  run ("thrown exceptions become error results").
  """

  alias Catalyst.Agent.Event
  alias Catalyst.{Content, Hooks, Message}
  alias Catalyst.Tools.Registry

  @type outcome :: %{message: Message.ToolResult.t(), terminate: boolean()}

  @doc "Run the batch; returns `{tool_result_messages, terminate?}`."
  def run_batch(tool_calls, config, emit) do
    outcomes =
      case batch_mode(tool_calls, config) do
        :sequential -> Enum.map(tool_calls, &run_one(&1, config, emit))
        :parallel -> run_parallel(tool_calls, config, emit)
      end

    results = Enum.map(outcomes, & &1.message)
    terminate? = outcomes != [] and Enum.all?(outcomes, & &1.terminate)
    {results, terminate?}
  end

  defp run_parallel(tool_calls, config, emit) do
    tool_calls
    |> Task.async_stream(&run_one(&1, config, emit),
      max_concurrency: Map.get(config, :max_tool_concurrency, System.schedulers_online()),
      ordered: true,
      timeout: Map.get(config, :tool_timeout, :infinity),
      on_timeout: :kill_task
    )
    |> Enum.zip(tool_calls)
    |> Enum.map(fn
      {{:ok, outcome}, _tool_call} -> outcome
      {{:exit, reason}, tool_call} -> failed_outcome(tool_call, reason, emit)
    end)
  end

  defp batch_mode(tool_calls, config) do
    cond do
      Map.get(config, :tool_execution) == :sequential -> :sequential
      Enum.any?(tool_calls, &(module_mode(&1, config) == :sequential)) -> :sequential
      true -> :parallel
    end
  end

  defp module_mode(tool_call, config) do
    case Registry.fetch(config.tools, tool_call.name) do
      nil -> :parallel
      module -> module.execution_mode()
    end
  end

  defp failed_outcome(tool_call, reason, emit) do
    %{id: id, name: name} = tool_call
    content = Content.text("tool runner failed: #{inspect(reason)}")

    emit.(%Event.ToolExecutionEnd{
      call_id: id,
      name: name,
      result: %{content: content, details: %{}},
      is_error: true
    })

    message = %Message.ToolResult{
      tool_call_id: id,
      tool_name: name,
      content: content,
      details: %{},
      is_error: true,
      timestamp: Message.now()
    }

    %{message: message, terminate: false}
  end

  defp run_one(tool_call, config, emit) do
    %{id: id, name: name, arguments: args} = tool_call
    emit.(%Event.ToolExecutionStart{call_id: id, name: name, args: args})

    hook_ctx = %{
      name: name,
      args: args,
      call_id: id,
      cwd: config.cwd,
      assistant: Map.get(config, :assistant)
    }

    raw =
      case Registry.fetch(config.tools, name) do
        nil ->
          {Content.text("unknown tool: #{name}"), %{}, true, false}

        module ->
          case Hooks.before_tool_call(hook_ctx) do
            {:block, reason} ->
              {Content.text(to_string(reason)), %{blocked: true}, true, false}

            _ ->
              ctx = %{
                cwd: config.cwd,
                call_id: id,
                session_id: Keyword.get(config[:opts] || [], :session_id),
                report: reporter(tool_call, emit)
              }

              execute_tool(module, args, ctx)
          end
      end

    # Hooks may override the result (content/details/is_error/terminate).
    {content, details, is_error, terminate} = Hooks.after_tool_call(raw, hook_ctx)

    emit.(%Event.ToolExecutionEnd{
      call_id: id,
      name: name,
      result: %{content: content, details: details},
      is_error: is_error
    })

    message = %Message.ToolResult{
      tool_call_id: id,
      tool_name: name,
      content: content,
      details: details,
      is_error: is_error,
      timestamp: Message.now()
    }

    %{message: message, terminate: terminate and not is_error}
  end

  defp execute_tool(module, args, ctx) do
    try do
      res = module.execute(args, ctx)
      {res.content, Map.get(res, :details, %{}), false, Map.get(res, :terminate, false)}
    rescue
      e -> {Content.text(Exception.message(e)), %{}, true, false}
    catch
      kind, reason -> {Content.text("#{kind}: #{inspect(reason)}"), %{}, true, false}
    end
  end

  defp reporter(tool_call, emit) do
    fn partial ->
      emit.(%Event.ToolExecutionUpdate{
        call_id: tool_call.id,
        name: tool_call.name,
        args: tool_call.arguments,
        partial: partial
      })
    end
  end
end
