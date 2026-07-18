defmodule Catalyst.Tools.SpawnAgent do
  @moduledoc """
  Spawns one isolated, file-prompted child session and returns its final answer.

  The tool accepts no model/provider/module arguments. Those capabilities come
  from the explicit `Catalyst.Tools.Context` assembled by the parent run. Child
  sessions share the parent's working directory and permission hooks, but own a
  fresh transcript and provider continuation.

  Child creation requires `Catalyst.Session.Manager.start_unique_session/1`.
  The function is feature-detected so this module can load independently while
  the session integration is being upgraded; the idempotent `start_session/1`
  API is never used as a fallback because doing so could adopt an unrelated
  live or persisted session after an identifier collision.
  """

  use Catalyst.Tools.Tool

  alias Catalyst.Agent.{Children, Event}
  alias Catalyst.{Content, Ids, Message, Tasks}
  alias Catalyst.Session.{Manager, Server}
  alias Catalyst.Tools.{ListAgents, Truncate}

  @max_task_bytes 32 * 1024
  @max_result_bytes 8 * 1024
  @notice_reserve_bytes 256
  @default_max_depth 3
  @default_max_concurrent 4
  @default_timeout 600_000
  @start_timeout 30_000
  @id_attempts 5

  @impl true
  def name, do: "spawn_agent"

  @impl true
  def description do
    "Run a named file-backed subagent in a fresh child session and return its final answer. " <>
      "Use list_agents first to discover available names."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "agent" => %{
          "type" => "string",
          "description" => "Name reported by list_agents (without .md)",
          "minLength" => 1,
          "maxLength" => 64
        },
        "task" => %{
          "type" => "string",
          "description" => "The nonblank task for the child session",
          "minLength" => 1,
          "maxLength" => @max_task_bytes
        }
      },
      "required" => ["agent", "task"],
      "additionalProperties" => false
    }
  end

  @impl true
  def execute(args, context) do
    case run(args, context) do
      {:ok, text, details} -> result(text, details)
      {:error, reason} -> raise "spawn_agent failed: #{inspect(reason)}"
    end
  end

  @doc "Run a child and return a tagged outcome (the implementation behind `execute/2`)."
  @spec run(map(), map()) :: {:ok, String.t(), map()} | {:error, term()}
  def run(args, context) when is_map(args) and is_map(context) do
    with {:ok, request} <- validate_request(args, context),
         :ok <- ensure_unique_start_api(),
         {:ok, definition} <- ListAgents.fetch(request.agent) do
      run_with_watchdog(request, definition)
    end
  end

  def run(args, _context), do: {:error, {:invalid_spawn_arguments, args}}

  defp validate_request(args, context) do
    agent = Map.get(args, "agent")
    task = Map.get(args, "task")
    opts = context_value(context, :opts, [])
    parent_id = parent_id(context)
    root_id = context_value(context, :root_session_id) || parent_id
    depth = context_value(context, :agent_depth, 0)

    with :ok <- ListAgents.validate_name(agent),
         {:ok, task} <- validate_task(task),
         :ok <- validate_context(context, parent_id, root_id, depth, opts),
         {:ok, limits} <- limits(opts),
         :ok <- ensure_depth(depth, limits.max_depth) do
      {:ok,
       %{
         agent: agent,
         task: task,
         cwd: context_value(context, :cwd),
         parent_id: parent_id,
         root_id: root_id,
         model: context_value(context, :model),
         provider: context_value(context, :provider),
         opts: opts,
         workflow: context_value(context, :workflow),
         tool_source: context_value(context, :tool_source, :extensions),
         child_depth: depth + 1,
         max_concurrent: limits.max_concurrent,
         timeout: limits.timeout
       }}
    end
  end

  defp validate_task(task) do
    cond do
      not is_binary(task) -> {:error, {:invalid_subagent_task, task}}
      not String.valid?(task) -> {:error, :invalid_utf8_subagent_task}
      String.trim(task) == "" -> {:error, :blank_subagent_task}
      byte_size(task) > @max_task_bytes -> {:error, {:subagent_task_too_large, byte_size(task)}}
      true -> {:ok, task}
    end
  end

  defp validate_context(context, parent_id, root_id, depth, opts) do
    cond do
      not nonblank?(context_value(context, :cwd)) ->
        {:error, {:invalid_subagent_cwd, context_value(context, :cwd)}}

      not nonblank?(parent_id) ->
        {:error, {:missing_subagent_inheritance, :parent_session_id}}

      not nonblank?(root_id) ->
        {:error, {:missing_subagent_inheritance, :root_session_id}}

      is_nil(context_value(context, :model)) ->
        {:error, {:missing_subagent_inheritance, :model}}

      is_nil(context_value(context, :provider)) ->
        {:error, {:missing_subagent_inheritance, :provider}}

      not (is_integer(depth) and depth >= 0) ->
        {:error, {:invalid_agent_depth, depth}}

      not Keyword.keyword?(opts) ->
        {:error, {:invalid_inheritable_options, opts}}

      true ->
        :ok
    end
  end

  defp limits(opts) do
    limits = %{
      max_depth: configured_limit(opts, :subagent_max_depth, @default_max_depth),
      max_concurrent: configured_limit(opts, :subagent_max_concurrent, @default_max_concurrent),
      timeout: configured_limit(opts, :subagent_timeout, @default_timeout)
    }

    cond do
      not (is_integer(limits.max_depth) and limits.max_depth >= 0) ->
        {:error, {:invalid_subagent_max_depth, limits.max_depth}}

      not (is_integer(limits.max_concurrent) and limits.max_concurrent > 0) ->
        {:error, {:invalid_subagent_max_concurrent, limits.max_concurrent}}

      not (is_integer(limits.timeout) and limits.timeout > 0) ->
        {:error, {:invalid_subagent_timeout, limits.timeout}}

      true ->
        {:ok, limits}
    end
  end

  defp ensure_depth(depth, max_depth) do
    case depth < max_depth do
      true -> :ok
      false -> {:error, {:subagent_depth_limit, depth, max_depth}}
    end
  end

  defp ensure_unique_start_api do
    case Code.ensure_loaded?(Manager) and function_exported?(Manager, :start_unique_session, 1) do
      true -> :ok
      false -> {:error, {:subagent_integration_unavailable, :start_unique_session}}
    end
  end

  defp run_with_watchdog(request, definition) do
    owner = self()
    token = make_ref()
    deadline = System.monotonic_time(:millisecond) + request.timeout

    case start_watchdog(owner, token, request, definition.prompt) do
      {:ok, watchdog} -> reserve_and_start(watchdog, owner, token, request, deadline)
      {:error, reason} -> {:error, {:subagent_watchdog_start, reason}}
    end
  end

  defp reserve_and_start(watchdog, owner, token, request, deadline) do
    case Children.reserve(request.root_id, request.parent_id, request.max_concurrent,
           caller: owner,
           keeper: watchdog
         ) do
      {:ok, lease} ->
        send(watchdog, {:begin_subagent_start, token})
        await_child_start(watchdog, token, request, lease, deadline)

      {:error, _reason} = error ->
        send(watchdog, {:cancel_subagent_start, token})
        error
    end
  end

  defp start_watchdog(owner, token, request, prompt) do
    Tasks.start_background(fn -> watchdog(owner, token, request, prompt) end)
  end

  # The supervised watchdog owns child creation and keeps the Children lease
  # alive until a started child is fully reaped. It is started before reservation
  # so caller death or a startup timeout cannot create an unaccounted child.
  defp watchdog(owner, token, request, prompt) do
    owner_monitor = Process.monitor(owner)

    receive do
      {:begin_subagent_start, ^token} ->
        start_watched_child(owner, owner_monitor, token, request, prompt)

      {:cancel_subagent_start, ^token} ->
        :ok

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        :ok
    end
  end

  defp start_watched_child(owner, owner_monitor, token, request, prompt) do
    case start_unique_child(request, prompt, @id_attempts) do
      {:ok, %{id: child_id, pid: child}} ->
        child_monitor = Process.monitor(child)

        case startup_cancelled?(owner, owner_monitor, token) do
          true ->
            Manager.stop(child_id)

          false ->
            send(owner, {:subagent_child_started, token, self(), child_id, child})
            watch_lifecycle(owner, owner_monitor, token, child_id, child, child_monitor)
        end

      {:error, reason} ->
        send(owner, {:subagent_child_start_failed, token, self(), reason})
    end
  end

  defp watch_lifecycle(owner, owner_monitor, token, child_id, child, child_monitor) do
    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        Manager.stop(child_id)

      {:DOWN, ^child_monitor, :process, ^child, _reason} ->
        :ok

      {:cancel_subagent_start, ^token} ->
        Manager.stop(child_id)
    end
  end

  defp startup_cancelled?(owner, owner_monitor, token) do
    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> true
      {:cancel_subagent_start, ^token} -> true
    after
      0 -> false
    end
  end

  defp start_unique_child(_request, _prompt, 0), do: {:error, :child_session_id_retries_exhausted}

  defp start_unique_child(request, prompt, attempts) do
    with {:ok, child_id} <- generate_child_id(request.parent_id) do
      opts = child_session_opts(request, prompt, child_id)

      case apply(Manager, :start_unique_session, [opts]) do
        {:ok, %{id: ^child_id, pid: child}} when is_pid(child) ->
          {:ok, %{id: child_id, pid: child}}

        {:error, reason} ->
          case collision?(reason) do
            true -> start_unique_child(request, prompt, attempts - 1)
            false -> {:error, {:child_session_start, reason}}
          end

        other ->
          {:error, {:invalid_unique_session_result, other}}
      end
    end
  catch
    :exit, reason -> {:error, {:child_session_start_exit, reason}}
  end

  defp generate_child_id(parent_id) do
    generator = Application.get_env(:catalyst, :subagent_id_generator, &Ids.hex/1)

    case invoke_id_generator(generator) do
      {:ok, suffix} -> build_child_id(parent_id, suffix)
      {:error, _reason} = error -> error
    end
  end

  defp build_child_id(parent_id, suffix) do
    case valid_id_suffix?(suffix) do
      true -> {:ok, parent_id <> "_s" <> suffix}
      false -> {:error, {:invalid_subagent_id_suffix, suffix}}
    end
  end

  defp invoke_id_generator(generator) when is_function(generator, 1) do
    {:ok, generator.(16)}
  rescue
    error -> {:error, {:subagent_id_generator, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:subagent_id_generator, {kind, reason}}}
  end

  defp invoke_id_generator(generator),
    do: {:error, {:invalid_subagent_id_generator, generator}}

  defp valid_id_suffix?(suffix) when is_binary(suffix),
    do: byte_size(suffix) == 32 and suffix =~ ~r/\A[0-9a-f]{32}\z/

  defp valid_id_suffix?(_suffix), do: false

  defp child_session_opts(request, prompt, child_id) do
    [
      id: child_id,
      cwd: request.cwd,
      system_prompt: prompt,
      model: request.model,
      provider: request.provider,
      tools: request.tool_source,
      opts: inherit_workflow(request.opts, request.workflow),
      workflow: request.workflow,
      parent_id: request.parent_id,
      root_session_id: request.root_id,
      agent_depth: request.child_depth,
      create: :exclusive
    ]
  end

  defp inherit_workflow(opts, nil), do: opts

  defp inherit_workflow(opts, {_name, module}) when is_atom(module),
    do: Keyword.put(opts, :loop, module)

  defp inherit_workflow(opts, %{module: module}) when is_atom(module),
    do: Keyword.put(opts, :loop, module)

  defp inherit_workflow(opts, module) when is_atom(module), do: Keyword.put(opts, :loop, module)
  defp inherit_workflow(opts, name) when is_binary(name), do: Keyword.put(opts, :workflow, name)
  defp inherit_workflow(opts, _other), do: opts

  defp collision?(reason) do
    case reason do
      :collision -> true
      :already_exists -> true
      {:collision, _id} -> true
      {:session_id_collision, _id} -> true
      {:session_exists, _id} -> true
      {:already_started, _pid} -> true
      {:already_exists, _id} -> true
      _other -> false
    end
  end

  defp await_child_start(watchdog, token, request, lease, deadline) do
    watchdog_monitor = Process.monitor(watchdog)

    receive do
      {:subagent_child_started, ^token, ^watchdog, child_id, child} ->
        attach_and_run(request, lease, child_id, child, watchdog_monitor, deadline)

      {:subagent_child_start_failed, ^token, ^watchdog, reason} ->
        Process.demonitor(watchdog_monitor, [:flush])
        {:error, reason}

      {:DOWN, ^watchdog_monitor, :process, ^watchdog, reason} ->
        {:error, {:subagent_watchdog_down, reason}}
    after
      min(remaining(deadline), @start_timeout) ->
        # Do not brutally kill a watchdog blocked in Manager: it may already
        # own a child. The queued cancellation makes it reap that child as soon
        # as the start call returns; the watchdog remains the lease keeper until
        # then, even when `run/2` was called by a long-lived process.
        send(watchdog, {:cancel_subagent_start, token})
        Process.demonitor(watchdog_monitor, [:flush])
        {:error, :subagent_start_timeout}
    end
  end

  defp attach_and_run(request, lease, child_id, child, watchdog_monitor, deadline) do
    case Children.attach(lease, child_id, child) do
      :ok -> run_child(request, child_id, child, watchdog_monitor, deadline)
      {:error, reason} -> stop_unattached_child(child_id, reason, watchdog_monitor)
    end
  end

  defp stop_unattached_child(child_id, reason, watchdog_monitor) do
    Manager.stop(child_id)
    Process.demonitor(watchdog_monitor, [:flush])
    {:error, reason}
  end

  defp run_child(request, child_id, child, watchdog_monitor, deadline) do
    topic = Server.topic(child_id)
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, topic)
    child_monitor = Process.monitor(child)

    try do
      with :ok <- prompt_child(child, request.task),
           {:ok, assistant} <-
             await_agent_end(child_id, child, child_monitor, watchdog_monitor, deadline),
           {:ok, text, details} <- result_payload(request.agent, child_id, assistant) do
        {:ok, text, details}
      end
    after
      Phoenix.PubSub.unsubscribe(Catalyst.PubSub, topic)
      Manager.stop(child_id)
      Process.demonitor(child_monitor, [:flush])
      Process.demonitor(watchdog_monitor, [:flush])
    end
  end

  defp prompt_child(child, task) do
    case Server.prompt(child, task) do
      :ok -> :ok
      {:error, reason} -> {:error, {:child_prompt, reason}}
    end
  catch
    :exit, reason -> {:error, {:child_prompt_exit, reason}}
  end

  defp await_agent_end(child_id, child, child_monitor, watchdog_monitor, deadline) do
    do_await_agent_end(child_id, child, child_monitor, watchdog_monitor, deadline)
  end

  defp do_await_agent_end(child_id, child, child_monitor, watchdog_monitor, deadline) do
    remaining = remaining(deadline)

    receive do
      {:agent_event, ^child_id, %Event.AgentEnd{messages: messages}} ->
        final_assistant(messages)

      {:agent_event, ^child_id, _event} ->
        do_await_agent_end(child_id, child, child_monitor, watchdog_monitor, deadline)

      {:DOWN, ^child_monitor, :process, ^child, reason} ->
        {:error, {:child_down_before_agent_end, reason}}

      {:DOWN, ^watchdog_monitor, :process, _watchdog, reason} ->
        {:error, {:subagent_watchdog_down, reason}}
    after
      remaining -> {:error, :subagent_timeout}
    end
  end

  defp remaining(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp final_assistant(messages) when is_list(messages) do
    case Enum.find(Enum.reverse(messages), &match?(%Message.Assistant{}, &1)) do
      nil -> {:error, :child_missing_assistant}
      assistant -> classify_assistant(assistant)
    end
  end

  defp final_assistant(_messages), do: {:error, :child_invalid_agent_end}

  defp classify_assistant(%Message.Assistant{stop_reason: :error} = assistant),
    do: {:error, {:child_provider_error, assistant.error_message}}

  defp classify_assistant(%Message.Assistant{stop_reason: :aborted}),
    do: {:error, :child_aborted}

  defp classify_assistant(%Message.Assistant{} = assistant) do
    text = Content.text_of(assistant.content) |> Truncate.scrub_utf8()

    case String.trim(text) do
      "" -> {:error, :child_blank_assistant}
      _nonblank -> {:ok, %{assistant | content: Content.text(text)}}
    end
  end

  defp result_payload(agent, child_id, assistant) do
    text = Content.text_of(assistant.content) |> Truncate.scrub_utf8()
    {bounded, info} = bounded_result(text)

    details = %{
      child_session_id: child_id,
      agent: agent,
      stop_reason: assistant.stop_reason,
      incomplete: assistant.stop_reason == :length,
      truncated: info.truncated,
      untrusted: true
    }

    {:ok, bounded, details}
  end

  defp bounded_result(text) do
    Truncate.head_notice(text,
      max_bytes: @max_result_bytes - @notice_reserve_bytes,
      max_lines: max(1, byte_size(text) + 1)
    )
  end

  defp parent_id(context) do
    context_value(context, :parent_session_id) || context_value(context, :session_id)
  end

  defp configured_limit(opts, key, default) do
    Keyword.get(opts, key, Application.get_env(:catalyst, key, default))
  end

  defp context_value(context, key, default \\ nil), do: Map.get(context, key, default)

  defp nonblank?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""
end
