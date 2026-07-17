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
  callbacks. Returns `{:ok, config}`, or `{:error, reason}` when the session has
  no resolvable provider — an expected configuration error that must not crash
  the session server.
  """
  @spec build(map(), pid()) :: {:ok, map()} | {:error, term()}
  def build(state, server) do
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
           get_steering: fn -> drain(server, :drain_steering) end,
           get_follow_up: fn -> drain(server, :drain_follow_up) end
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
    GenServer.call(server, message)
  catch
    :exit, _reason -> []
  end
end
