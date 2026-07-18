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
  alias Catalyst.Session.RunConfig
  alias Catalyst.Tools.{Context, Registry, Truncate}

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

    run_batch_with_index(tool_calls, index, config, emit)
  end

  @doc false
  @spec run_batch_with_index([tool_call()], Registry.index(), map(), (struct() -> any())) ::
          {[Message.ToolResult.t()], boolean()}
  def run_batch_with_index(tool_calls, index, config, emit) do
    names = Enum.map(tool_calls, & &1.name)

    outcomes =
      case Registry.validate_index(index, names) do
        :ok -> run_current_batch(tool_calls, index, config, emit)
        {:error, reason} -> fail_batch(tool_calls, reason, emit)
      end

    finish_batch(outcomes)
  end

  defp run_current_batch(tool_calls, index, config, emit) do
    case batch_mode(tool_calls, config, index) do
      :sequential -> run_stream(tool_calls, index, config, emit, 1)
      :parallel -> run_stream(tool_calls, index, config, emit, max_concurrency(config))
    end
  end

  defp finish_batch(outcomes) do
    results = Enum.map(outcomes, & &1.message)
    # The batch terminates the loop only when EVERY call asked to (PI parity:
    # `toolResults.every((r) => r.terminate === true)`), so one terminating
    # tool can't cut off siblings' pending work.
    terminate? = outcomes != [] and Enum.all?(outcomes, & &1.terminate)
    {results, terminate?}
  end

  defp fail_batch(tool_calls, reason, emit) do
    Enum.map(tool_calls, fn %{id: id, name: name, arguments: args} = tool_call ->
      emit_tool_start(id, name, args, emit)
      failed_outcome(tool_call, reason, emit, stale_details(reason))
    end)
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
    case Registry.fetch_entry(index, tool_call.name) do
      {:ok, entry} -> entry.definition.execution_mode
      :error -> :parallel
    end
  end

  defp failed_outcome(tool_call, reason, emit, details \\ %{}) do
    %{id: id, name: name} = tool_call
    content = Content.text("tool runner failed: #{inspect(reason)}")

    emit_tool_end(id, name, content, details, true, emit)

    message = build_tool_result_message(id, name, content, details, true)

    %{message: message, terminate: false}
  end

  defp run_one(%{id: id, name: name, arguments: args} = tool_call, index, config, emit) do
    emit_tool_start(id, name, args, emit)

    hook_ctx = build_hook_context(id, name, args, config)

    raw_result = run_registered_tool(index, name, args, tool_call, hook_ctx, config, emit)

    {content, details, error?, terminate} = apply_after_tool_hook(raw_result, hook_ctx, config)
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
    case Registry.fetch_entry(index, name) do
      :error ->
        unknown_tool_result(name)

      {:ok, entry} ->
        run_resolved_tool(entry, args, tool_call, hook_ctx, config, emit)
    end
  end

  defp run_resolved_tool(entry, args, tool_call, hook_ctx, config, emit) do
    case before_tool_call(hook_ctx, config) do
      {:block, reason} ->
        blocked_tool_result(reason)

      _ ->
        ctx = build_execution_context(tool_call, config, emit)

        execute_tool(entry, args, ctx)
    end
  end

  defp build_execution_context(tool_call, config, emit) do
    Context.new(
      cwd: config.cwd,
      call_id: tool_call.id,
      parent_session_id: Map.get(config, :parent_session_id, session_id(config)),
      root_session_id: Map.get(config, :root_session_id, session_id(config)),
      model: Map.get(config, :model),
      provider: Map.get(config, :provider),
      opts: current_inheritable_opts(config),
      workflow: Map.get(config, :workflow),
      tool_source: Map.get(config, :tool_source, Map.get(config, :tools, :extensions)),
      agent_depth: Map.get(config, :agent_depth, 0),
      report: reporter(tool_call, emit)
    )
  end

  defp session_id(config), do: Keyword.get(config[:opts] || [], :session_id)

  # Prefer the live turn opts so prepare_next_turn option changes (reasoning,
  # thresholds, provider tuning) flow into subsequently spawned children.
  defp current_inheritable_opts(config) do
    case Map.get(config, :opts) do
      opts when is_list(opts) -> RunConfig.inheritable_opts(opts)
      _missing -> Map.get(config, :inheritable_opts, [])
    end
  end

  defp unknown_tool_result(name) do
    {Content.text("unknown tool: #{name}"), %{}, true, false}
  end

  defp blocked_tool_result(reason) do
    {Content.text(format_block_reason(reason)), %{blocked: true}, true, false}
  end

  defp format_block_reason(reason) when is_binary(reason), do: reason
  defp format_block_reason(reason), do: inspect(reason)

  defp before_tool_call(hook_ctx, config) do
    case Map.get(config, :hook_snapshot) do
      snapshot when is_map(snapshot) -> Hooks.before_tool_call(hook_ctx, snapshot)
      _missing -> Hooks.before_tool_call(hook_ctx)
    end
  end

  defp apply_after_tool_hook(raw_result, hook_ctx, config) do
    # Hooks may override the result (content/details/is_error/terminate).
    case Map.get(config, :hook_snapshot) do
      snapshot when is_map(snapshot) -> Hooks.after_tool_call(raw_result, hook_ctx, snapshot)
      _missing -> Hooks.after_tool_call(raw_result, hook_ctx)
    end
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

  defp execute_tool(entry, args, ctx) do
    with :ok <- validate_args(entry.resolved_schema, args),
         {:ok, executor} <- Registry.execution_target(entry) do
      call_executor(executor, args, ctx)
    else
      {:error, message} when is_binary(message) ->
        {Content.text(message), %{validation: :failed}, true, false}

      {:error, {:stale_tool_entry, _module} = reason} ->
        {Content.text("tool runner failed: #{inspect(reason)}"), stale_details(reason), true,
         false}
    end
  end

  defp call_executor(executor, args, ctx) do
    try do
      res = executor.(args, ctx)
      {res.content, Map.get(res, :details, %{}), false, Map.get(res, :terminate, false)}
    rescue
      e -> {Content.text(Exception.message(e)), %{}, true, false}
    catch
      kind, reason -> {Content.text("#{kind}: #{inspect(reason)}"), %{}, true, false}
    end
  end

  defp stale_details(reason), do: %{validation: :stale_tool_entry, reason: reason}

  # Validate args against the tool's declared JSON Schema, so a malformed call
  # (most common with self-developed tools) becomes a clean, fixable error
  # result instead of a confusing crash inside execute/2. An unresolvable
  # schema retains the legacy permissive behavior; a validator crash does not.
  defp validate_args(resolved_schema, args) do
    case resolved_schema do
      {:ok, schema} -> check_args(schema, args)
      :error -> :ok
    end
  end

  defp check_args(schema, args) do
    case argument_validator().(schema, args) do
      :ok ->
        :ok

      {:error, errors} ->
        details = Enum.map_join(errors, "; ", fn {msg, path} -> "#{path}: #{msg}" end)
        {:error, "invalid arguments: " <> details}
    end
  rescue
    e -> {:error, "invalid arguments: validation exception: #{Exception.message(e)}"}
  catch
    kind, reason -> {:error, "invalid arguments: validation #{kind}: #{inspect(reason)}"}
  end

  defp argument_validator do
    Application.get_env(:catalyst, :tool_argument_validator, &ExJsonSchema.Validator.validate/2)
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
