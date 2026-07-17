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
  alias Catalyst.Content.Text
  alias Catalyst.Tools.{Registry, Truncate}

  @type outcome :: %{message: Message.ToolResult.t(), terminate: boolean()}

  @typedoc "A tool call issued by the assistant (`Catalyst.Content.ToolCall` or a compatible map)."
  @type tool_call :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:arguments) => map(),
          optional(atom()) => any()
        }

  @doc """
  Run the batch; returns `{tool_result_messages, terminate?}`.

  `config` must carry `:tools` (the tool module list) and `:cwd`; optional keys
  are `:tool_execution`, `:max_tool_concurrency`, `:tool_timeout`, `:assistant`,
  and `:opts`. `emit` receives `Catalyst.Agent.Event` structs as side effects.
  Results preserve the assistant's call order, and a raising/exiting tool
  becomes an error tool-result instead of crashing the run.
  """
  @spec run_batch([tool_call()], map(), (struct() -> any())) ::
          {[Message.ToolResult.t()], boolean()}
  def run_batch(tool_calls, config, emit) do
    index = Registry.index(config.tools)

    outcomes =
      case batch_mode(tool_calls, config, index) do
        :sequential -> run_stream(tool_calls, index, config, emit, 1)
        :parallel -> run_stream(tool_calls, index, config, emit, max_concurrency(config))
      end

    results = Enum.map(outcomes, & &1.message)
    # The batch terminates the loop only when EVERY call asked to (PI parity:
    # `toolResults.every((r) => r.terminate === true)`), so one terminating
    # tool can't cut off siblings' pending work.
    terminate? = outcomes != [] and Enum.all?(outcomes, & &1.terminate)
    {results, terminate?}
  end

  defp run_stream(tool_calls, index, config, emit, max_concurrency) do
    tool_calls
    |> Task.async_stream(&run_one(&1, index, config, emit),
      max_concurrency: max_concurrency,
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

  defp max_concurrency(config),
    do: Map.get(config, :max_tool_concurrency, System.schedulers_online())

  defp batch_mode(tool_calls, config, index) do
    cond do
      Map.get(config, :tool_execution) == :sequential -> :sequential
      Enum.any?(tool_calls, &(module_mode(index, &1) == :sequential)) -> :sequential
      true -> :parallel
    end
  end

  defp module_mode(index, tool_call) do
    case Registry.fetch(index, tool_call.name) do
      {:ok, module} -> declared_mode(module)
      :error -> :parallel
    end
  end

  # `execution_mode/0` is an optional callback (the default is injected by
  # `use Catalyst.Tools.Tool`), so a bare behaviour implementation may omit it.
  defp declared_mode(module) do
    case Code.ensure_loaded?(module) and function_exported?(module, :execution_mode, 0) do
      true -> module.execution_mode()
      false -> :parallel
    end
  end

  defp failed_outcome(tool_call, reason, emit) do
    %{id: id, name: name} = tool_call
    content = Content.text("tool runner failed: #{inspect(reason)}")
    details = %{}

    emit_tool_end(id, name, content, details, true, emit)

    message = build_tool_result_message(id, name, content, details, true)

    %{message: message, terminate: false}
  end

  defp run_one(%{id: id, name: name, arguments: args} = tool_call, index, config, emit) do
    emit_tool_start(id, name, args, emit)

    hook_ctx = build_hook_context(id, name, args, config)

    raw_result = run_registered_tool(index, name, args, tool_call, hook_ctx, config, emit)

    {content, details, error?, terminate} = apply_after_tool_hook(raw_result, hook_ctx)
    content = scrub_text_content(content)

    emit_tool_end(id, name, content, details, error?, emit)

    message = build_tool_result_message(id, name, content, details, error?)
    terminate? = terminate and not error?

    %{message: message, terminate: terminate?}
  end

  defp emit_tool_start(id, name, args, emit) do
    emit.(%Event.ToolExecutionStart{call_id: id, name: name, args: args})
  end

  defp build_hook_context(id, name, args, config) do
    %{
      name: name,
      args: args,
      call_id: id,
      cwd: config.cwd,
      assistant: Map.get(config, :assistant)
    }
  end

  defp run_registered_tool(index, name, args, tool_call, hook_ctx, config, emit) do
    case Registry.fetch(index, name) do
      :error ->
        unknown_tool_result(name)

      {:ok, module} ->
        run_resolved_tool(module, args, tool_call, hook_ctx, config, emit)
    end
  end

  defp run_resolved_tool(module, args, tool_call, hook_ctx, config, emit) do
    case Hooks.before_tool_call(hook_ctx) do
      {:block, reason} ->
        blocked_tool_result(reason)

      _ ->
        ctx = build_execution_context(tool_call, config, emit)

        execute_tool(module, args, ctx)
    end
  end

  defp build_execution_context(tool_call, config, emit) do
    %{
      cwd: config.cwd,
      call_id: tool_call.id,
      session_id: Keyword.get(config[:opts] || [], :session_id),
      report: reporter(tool_call, emit)
    }
  end

  defp unknown_tool_result(name) do
    {Content.text("unknown tool: #{name}"), %{}, true, false}
  end

  defp blocked_tool_result(reason) do
    {Content.text(format_block_reason(reason)), %{blocked: true}, true, false}
  end

  defp format_block_reason(reason) when is_binary(reason), do: reason
  defp format_block_reason(reason), do: inspect(reason)

  defp apply_after_tool_hook(raw_result, hook_ctx) do
    # Hooks may override the result (content/details/is_error/terminate).
    Hooks.after_tool_call(raw_result, hook_ctx)
  end

  defp scrub_text_content(content) do
    Enum.map(content, fn
      %Text{text: text} = block -> %{block | text: Truncate.scrub_utf8(text)}
      block -> block
    end)
  end

  defp emit_tool_end(id, name, content, details, error?, emit) do
    emit.(%Event.ToolExecutionEnd{
      call_id: id,
      name: name,
      result: %{content: content, details: details},
      is_error: error?
    })
  end

  defp build_tool_result_message(id, name, content, details, error?) do
    %Message.ToolResult{
      tool_call_id: id,
      tool_name: name,
      content: content,
      details: details,
      is_error: error?,
      timestamp: Message.now()
    }
  end

  defp execute_tool(module, args, ctx) do
    case validate_args(module, args) do
      {:error, message} ->
        {Content.text(message), %{validation: :failed}, true, false}

      :ok ->
        try do
          res = module.execute(args, ctx)
          {res.content, Map.get(res, :details, %{}), false, Map.get(res, :terminate, false)}
        rescue
          e -> {Content.text(Exception.message(e)), %{}, true, false}
        catch
          kind, reason -> {Content.text("#{kind}: #{inspect(reason)}"), %{}, true, false}
        end
    end
  end

  # Validate args against the tool's declared JSON Schema, so a malformed call
  # (most common with self-developed tools) becomes a clean, fixable error
  # result instead of a confusing crash inside execute/2. A schema that itself
  # fails to resolve (or a crashing validator) skips validation rather than
  # blocking the tool.
  defp validate_args(module, args) do
    case resolved_schema(module) do
      {:ok, schema} -> check_args(schema, args)
      :error -> :ok
    end
  end

  defp check_args(schema, args) do
    case ExJsonSchema.Validator.validate(schema, args) do
      :ok ->
        :ok

      {:error, errors} ->
        details = Enum.map_join(errors, "; ", fn {msg, path} -> "#{path}: #{msg}" end)
        {:error, "invalid arguments: " <> details}
    end
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  # Resolving a schema is expensive, so cache the result in :persistent_term,
  # ONE entry per tool module holding {params, resolved}: a hot-reloaded
  # tool whose schema changed REPLACES its entry (exact mismatch → re-resolve)
  # instead of accumulating one permanent entry per schema version, while
  # unchanged tools hit the cache.
  defp resolved_schema(module) do
    with {:ok, %{parameters: params}} <- Registry.cached_definition(module) do
      key = {__MODULE__, module}

      case :persistent_term.get(key, :unresolved) do
        {^params, resolved} -> resolved
        _missing_or_stale -> cache_schema(key, params)
      end
    else
      {:error, _reason} -> :error
    end
  rescue
    _ -> :error
  catch
    _kind, _reason -> :error
  end

  defp cache_schema(key, params) do
    resolved = resolve_schema(params)
    :persistent_term.put(key, {params, resolved})
    resolved
  end

  defp resolve_schema(params) do
    # Normalize atom keys/values (hand-written schemas) to JSON shape.
    {:ok, params |> Jason.encode!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()}
  rescue
    _ -> :error
  catch
    _kind, _reason -> :error
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
