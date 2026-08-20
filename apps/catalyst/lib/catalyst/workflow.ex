defmodule Catalyst.Workflow do
  @moduledoc """
  Behaviour implemented by agent workflows.

  A workflow owns one complete agent run. Its argument and return contract is
  the same as `Catalyst.Agent.Loop.run/4`; conforming workflows use
  `Catalyst.Workflow.Support` for observed event emission, live tool
  resolution, capability filtering, and ordinary provider requests.
  """

  alias Catalyst.Agent.Event
  alias Catalyst.Message
  alias Catalyst.Workflow.Registry

  @type emitter :: (Event.t() -> any())
  @type result :: {:ok, [Message.t()], map()} | {:error, term()}

  @doc """
  Run one complete agent workflow.

  `prompts` and the returned new-message list are chronological. Emit lifecycle
  and persistable message events through `emitter`; use `Workflow.Support` for
  guarded provider requests, observers, and capability filtering.
  """
  @callback run([Message.t()], map(), map(), emitter()) :: result()

  @doc "Return whether the workflow needs a resolved `Catalyst.LLM.Provider`."
  @callback provider_required?() :: boolean()

  @doc "Return optional diagnostic metadata describing the workflow."
  @callback describe() :: term()

  @optional_callbacks describe: 0, provider_required?: 0

  @doc "Return whether `module` requires a provider, defaulting to `true`."
  @spec provider_required?(module()) :: boolean()
  def provider_required?(module) when is_atom(module) do
    case function_exported?(module, :provider_required?, 0) do
      true -> module.provider_required?()
      false -> true
    end
  end

  @doc "Resolve the workflow selected by the supplied run options."
  @spec resolve(keyword() | map()) :: {:ok, Registry.selection()} | {:error, term()}
  defdelegate resolve(opts), to: Registry
end
