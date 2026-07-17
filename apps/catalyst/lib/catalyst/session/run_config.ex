defmodule Catalyst.Session.RunConfig do
  @moduledoc """
  Builds the `Catalyst.Agent.Loop` config for a run, including resolving the
  session's provider through `Catalyst.LLM.Registry`. Extracted from the GenServer
  so the run-assembly + provider-resolution rules can be hot-reloaded.
  """

  alias Catalyst.Model
  alias Catalyst.LLM.Registry

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
           opts: Keyword.put_new(state.opts, :session_id, state.id),
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
