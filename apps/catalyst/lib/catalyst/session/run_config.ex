defmodule Catalyst.Session.RunConfig do
  @moduledoc """
  Builds the `Catalyst.Agent.Loop` config for a run, including resolving the
  session's provider through `Catalyst.LLM.Registry`. Extracted from the GenServer
  so the run-assembly + provider-resolution rules can be hot-reloaded.
  """

  alias Catalyst.{Model, Tasks}
  alias Catalyst.LLM.Registry

  require Logger

  @provider_cleanup_timeout 1_000

  @doc """
  Assemble the loop config for `state`; `server` backs the steering/follow-up
  callbacks and `run_ref` scopes them to this run — the server replies `[]` to a
  drain carrying a stale ref, so a drain racing an abort can't move queued
  messages into a run that can no longer deliver them. Returns `{:ok, config}`,
  or `{:error, reason}` when the session has no resolvable provider — an
  expected configuration error that must not crash the session server.
  """
  @spec build(map(), pid(), reference()) :: {:ok, map()} | {:error, term()}
  def build(state, server, run_ref) do
    case resolve_provider(state) do
      {:ok, provider} ->
        {:ok,
         %{
           loop: resolve_loop(state),
           provider: provider,
           model: state.model,
           cwd: state.cwd,
           tools: state.tools,
           # Stable session id → Codex prompt_cache_key + request headers.
           # `:session_id` is an internal identity, never caller-overridable.
           opts: Keyword.put(state.opts, :session_id, state.id),
           get_steering: fn -> drain(server, {:drain_steering, run_ref}) end,
           get_follow_up: fn -> drain(server, {:drain_follow_up, run_ref}) end
         }}

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Resolve the loop module driving the run — data, not a hardcoded call: the
  session's `opts[:loop]`, else the `:agent_loop` application env, else
  `Catalyst.Agent.Loop`. An extension swaps the agent loop for every session with
  `Application.put_env(:catalyst, :agent_loop, MyLoop)` (live on the next run)
  and reverts by deleting the env; the module must export `run/4` with
  `Catalyst.Agent.Loop`'s contract.
  """
  @spec resolve_loop(map()) :: module()
  def resolve_loop(state) do
    Keyword.get(state.opts || [], :loop) ||
      Application.get_env(:catalyst, :agent_loop, Catalyst.Agent.Loop)
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
      model = state.model
      opts = Keyword.put(state.opts, :session_id, state.id)

      context = %Catalyst.LLM.Context{
        system_prompt: state.system_prompt || Catalyst.SystemPrompt.get(),
        # Server state holds messages newest-first; requests are chronological.
        messages: Enum.reverse(state.messages),
        tools: Catalyst.Tools.Registry.to_provider_tools(Catalyst.Extensions.resolve(state.tools))
      }

      Tasks.start_background(fn -> provider.prewarm(model, context, opts) end)
    else
      _no_provider_or_no_prewarm -> :ok
    end
  end

  @doc """
  Let every live provider release session-scoped resources.

  Providers without the optional `cleanup_session/1` callback are a no-op.
  Cleanup failures are isolated because session termination must still finish.
  """
  @spec cleanup_session(map()) :: :ok
  def cleanup_session(state) do
    state
    |> cleanup_providers()
    |> Enum.each(&cleanup_provider(&1, state.id))

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

  defp cleanup_provider(provider, session_id) do
    case Code.ensure_loaded?(provider) and function_exported?(provider, :cleanup_session, 1) do
      true -> run_provider_cleanup(provider, session_id)
      false -> :ok
    end
  end

  defp run_provider_cleanup(provider, session_id) do
    task = Tasks.async(fn -> provider.cleanup_session(session_id) end)

    case Tasks.await(task, provider_cleanup_timeout()) do
      {:ok, _result} -> :ok
      {:exit, reason} -> log_cleanup_failure(provider, session_id, {:exit, reason})
      :timeout -> log_cleanup_failure(provider, session_id, :timeout)
    end
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

  defp drain(server, message) do
    # :infinity is deliberate: a finite timeout abandons a call the server still
    # processes later (draining into a run that can't deliver), while the call
    # exits promptly if the server dies and a stale-ref drain is a server-side
    # no-op, so there is nothing to time out on.
    GenServer.call(server, message, :infinity)
  catch
    :exit, _reason -> []
  end
end
