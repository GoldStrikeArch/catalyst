defmodule Catalyst.Session.RunConfig do
  @moduledoc """
  Builds the host-owned portion of a workflow run configuration and resolves
  the session's provider through `Catalyst.LLM.Registry`. Extracted from the
  GenServer so run assembly and provider-resolution rules can be hot-reloaded.
  """

  alias Catalyst.Agent.Event
  alias Catalyst.{Message, Model, Tasks}
  alias Catalyst.LLM.Registry
  alias Catalyst.Session.{EventSink, RunContext}

  require Logger

  @provider_cleanup_timeout 1_000

  @typedoc """
  Immutable configuration for one run.

  The map is deliberately open: workflow and hook extensions may add keys for
  later turns without requiring a core struct upgrade.
  """
  @type t :: %{
          required(:provider) => module(),
          required(:model) => Model.t() | nil,
          required(:cwd) => String.t(),
          required(:tools) => term(),
          required(:tool_source) => term(),
          required(:tool_profile) => term(),
          required(:parent_session_id) => String.t(),
          required(:root_session_id) => String.t(),
          required(:agent_depth) => non_neg_integer(),
          required(:opts) => keyword(),
          required(:inheritable_opts) => keyword(),
          required(:get_steering) => (-> [Message.t()]),
          required(:get_follow_up) => (-> [Message.t()]),
          required(:register_resource) => (map() -> :ok | {:error, term()}),
          required(:persist_event) => (Event.t() -> :ok | {:error, term()}),
          required(:report_metadata) => (map() -> :ok),
          optional(atom()) => term()
        }

  @doc """
  Build the callback/provider/tool portion of a run without invoking prompt or
  workflow policy code. `Session.RunContext` calls this only after the
  supervised run task has started.
  """
  @spec build_base(map(), pid(), reference(), module()) :: {:ok, t()}
  def build_base(state, server, run_ref, provider) do
    opts = Keyword.put(state.opts || [], :session_id, state.id)
    source = Map.get(state, :tools, :extensions)

    {:ok,
     %{
       provider: provider,
       model: state.model,
       cwd: state.cwd,
       tools: source,
       tool_source: source,
       tool_profile: Keyword.get(opts, :tool_profile, "coding"),
       parent_session_id: state.id,
       root_session_id: Map.get(state, :root_session_id) || state.id,
       agent_depth: Map.get(state, :agent_depth, 0),
       opts: opts,
       inheritable_opts: inheritable_opts(opts),
       get_steering: fn -> drain(server, {:drain_steering, run_ref}) end,
       get_follow_up: fn -> drain(server, {:drain_follow_up, run_ref}) end,
       register_resource: fn resource -> register_resource(server, run_ref, resource) end,
       persist_event: fn event -> EventSink.persist(server, run_ref, event) end,
       report_metadata: fn metadata ->
         GenServer.cast(server, {:run_metadata, run_ref, metadata})
       end
     }}
  end

  @doc """
  Resolve the provider to a concrete module: a module is used directly
  (back-compat); a binary api/name is resolved through the live provider registry;
  otherwise the model's `api` selects the provider. Returns `{:ok, module}` or
  `{:error, :no_provider | {:unknown_api, api}}`.
  """
  @spec resolve_provider(map()) :: {:ok, module()} | {:error, term()}
  def resolve_provider(%{provider: provider}) when is_binary(provider),
    do: Registry.fetch(provider)

  def resolve_provider(%{provider: provider}) when is_atom(provider) and not is_nil(provider),
    do: {:ok, provider}

  def resolve_provider(%{provider: nil, model: %Model{api: api}}) when is_binary(api),
    do: Registry.fetch(api)

  def resolve_provider(_), do: {:error, :no_provider}

  @doc """
  Start provider warmup: when the session's provider exports
  `prewarm/3` (the Codex websocket warmup, `"generate": false`), build the
  same context the next run would send and call it in a supervised task —
  the first turn then rides a connection-scoped delta upload. Providers
  without `prewarm/3` (Faux, Demo, …) make this a no-op.
  """
  @spec start_prewarm(map()) :: {:ok, pid()} | {:error, term()} | :ok
  def start_prewarm(state) do
    with {:ok, provider} <- resolve_provider(state),
         true <- Code.ensure_loaded?(provider) and function_exported?(provider, :prewarm, 3) do
      Tasks.start_background(fn -> prewarm(provider, state) end)
    else
      _no_provider_or_no_prewarm -> :ok
    end
  end

  @doc """
  Let every live provider release session-scoped resources.

  Providers without the optional `cleanup_session/1` callback are a no-op.
  Cleanup callbacks run concurrently under one shared deadline; failures are
  isolated because session termination must still finish.
  """
  @spec cleanup_session(map()) :: :ok
  def cleanup_session(state) do
    cleanups =
      state
      |> cleanup_providers()
      |> Enum.filter(&cleanup_provider?/1)
      |> Enum.map(fn provider ->
        {provider, Tasks.async(fn -> call_provider_cleanup(provider, state.id) end)}
      end)

    provider_by_ref = Map.new(cleanups, fn {provider, task} -> {task.ref, provider} end)
    tasks = Enum.map(cleanups, &elem(&1, 1))

    tasks
    |> Task.yield_many(provider_cleanup_timeout())
    |> Enum.each(fn {task, result} ->
      provider = Map.fetch!(provider_by_ref, task.ref)
      finish_provider_cleanup(provider, state.id, task, result)
    end)

    :ok
  end

  defp cleanup_providers(state) do
    registered =
      Registry.list()
      |> Map.values()
      |> Enum.map(& &1.module)

    selected =
      case resolve_provider(state) do
        {:ok, provider} -> [provider]
        {:error, _reason} -> []
      end

    Enum.uniq(selected ++ registered)
  end

  defp call_provider_cleanup(provider, session_id) do
    {:ok, provider.cleanup_session(session_id)}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp cleanup_provider?(provider),
    do: Code.ensure_loaded?(provider) and function_exported?(provider, :cleanup_session, 1)

  defp finish_provider_cleanup(_provider, _session_id, _task, {:ok, {:ok, _result}}), do: :ok

  defp finish_provider_cleanup(provider, session_id, _task, {:ok, {:error, reason}}),
    do: log_cleanup_failure(provider, session_id, reason)

  defp finish_provider_cleanup(provider, session_id, _task, {:exit, reason}),
    do: log_cleanup_failure(provider, session_id, {:exit, reason})

  defp finish_provider_cleanup(provider, session_id, task, nil) do
    _result = Task.shutdown(task, :brutal_kill)
    log_cleanup_failure(provider, session_id, :timeout)
  end

  defp log_cleanup_failure(provider, session_id, reason) do
    Logger.warning(
      "[session] provider #{inspect(provider)} cleanup for #{session_id} failed: " <>
        inspect(reason)
    )

    :ok
  end

  defp provider_cleanup_timeout,
    do: Application.get_env(:catalyst, :provider_cleanup_timeout, @provider_cleanup_timeout)

  defp register_resource(server, run_ref, resource) do
    GenServer.call(server, {:register_run_resource, run_ref, resource}, :infinity)
  catch
    :exit, reason -> {:error, {:resource_registration_failed, reason}}
  end

  defp drain(server, message) do
    # :infinity is deliberate: a finite timeout abandons a call the server still
    # processes later (draining into a run that can't deliver), while the call
    # exits promptly if the server dies and a stale-ref drain is a server-side
    # no-op, so there is nothing to time out on.
    GenServer.call(server, message, :infinity)
  catch
    :exit, _reason -> []
  end

  defp prewarm(provider, state) do
    with {:ok, prompt} <- RunContext.resolve_prompt(state, state.model) do
      context = %Catalyst.LLM.Context{
        system_prompt: prompt.text,
        # Server state holds messages newest-first; requests are chronological.
        messages: Enum.reverse(state.messages),
        tools:
          %{
            tools: state.tools,
            tool_source: state.tools,
            tool_profile: Keyword.get(state.opts || [], :tool_profile, "coding"),
            opts: state.opts || [],
            agent_depth: Map.get(state, :agent_depth, 0)
          }
          |> Catalyst.Workflow.Support.resolve_tools()
          |> Catalyst.Tools.Registry.to_provider_tools()
      }

      opts = Keyword.put(state.opts || [], :session_id, state.id)
      provider.prewarm(state.model, context, opts)
    else
      {:error, reason} ->
        Logger.warning("[session] prewarm prompt resolution failed: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("[session] prewarm failed: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("[session] prewarm #{kind}: #{inspect(reason)}")
      :ok
  end

  @doc """
  Return provider/context options safe to copy into a child run.

  Process terms and parent-only controls are dropped. `:computer_use` is
  dropped for a second reason: it is a machine-access **grant**, and a bare
  boolean would otherwise pass `inheritable_term?/1` and hand every subagent
  spawned by a prompt-injected run full control of the machine. A child session
  therefore never inherits computer use — it must be granted explicitly.
  """
  @spec inheritable_opts(keyword()) :: keyword()
  def inheritable_opts(opts) when is_list(opts) do
    opts
    |> Keyword.drop([
      :computer_use,
      :session_id,
      :system_prompt,
      :loop,
      :workflow,
      :get_steering,
      :get_follow_up,
      :convert_to_llm,
      :register_resource,
      :persist_event,
      :report_metadata,
      :report,
      :call_id,
      :parent_session_id,
      :root_session_id,
      :agent_depth,
      :task
    ])
    |> Enum.filter(fn {_key, value} -> inheritable_term?(value) end)
  end

  defp inheritable_term?(value)
       when is_function(value) or is_pid(value) or is_port(value) or is_reference(value),
       do: false

  # Walk lists cell by cell: an improper tail (e.g. `[1 | 2]`) satisfies
  # is_list/1 but crashes Enum.all?/2, so it is rejected rather than raised on.
  defp inheritable_term?(value) when is_list(value), do: inheritable_list?(value)

  defp inheritable_term?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> inheritable_term?(key) and inheritable_term?(item) end)

  defp inheritable_term?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.all?(&inheritable_term?/1)

  defp inheritable_term?(_value), do: true

  defp inheritable_list?([]), do: true
  defp inheritable_list?([head | tail]), do: inheritable_term?(head) and inheritable_list?(tail)
  defp inheritable_list?(_improper_tail), do: false
end
