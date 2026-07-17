defmodule Catalyst.Session.RunConfig do
  @moduledoc """
  Builds the `Catalyst.Agent.Loop` config for a run, including resolving the
  session's provider through `Catalyst.LLM.Registry`. Extracted from the GenServer
  so the run-assembly + provider-resolution rules can be hot-reloaded.
  """

  alias Catalyst.Model
  alias Catalyst.LLM.Registry

  @doc "Assemble the loop config for `state`; `server` backs the steering/follow-up callbacks."
  def build(state, server) do
    %{
      provider: resolve_provider(state),
      model: state.model,
      cwd: state.cwd,
      tools: state.tools,
      # Stable session id → Codex prompt_cache_key + request headers.
      opts: Keyword.put_new(state.opts, :session_id, state.id),
      get_steering: fn -> GenServer.call(server, :drain_steering) end,
      get_follow_up: fn -> GenServer.call(server, :drain_follow_up) end
    }
  end

  @doc """
  Resolve the provider to a concrete module: a module is used directly
  (back-compat); a binary api/name is resolved through the live provider registry;
  otherwise the model's `api` selects the provider.
  """
  def resolve_provider(%{provider: provider}) when is_binary(provider),
    do: Registry.fetch!(provider)

  def resolve_provider(%{provider: provider}) when is_atom(provider) and not is_nil(provider),
    do: provider

  def resolve_provider(%{provider: nil, model: %Model{api: api}}) when is_binary(api),
    do: Registry.fetch!(api)

  def resolve_provider(_),
    do: raise(ArgumentError, "session has no provider configured")
end
