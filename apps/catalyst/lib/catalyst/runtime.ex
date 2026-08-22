defmodule Catalyst.Runtime do
  @moduledoc """
  Public entry point for runtime service resolution and introspection.

  Provides a pure generic resolver, host-extensible read model, generic
  extension-point declarations, and the first production adapter:
  `agent.run_engine`. Specialized subsystem registries remain authoritative
  execution stores while later phases migrate them behind this semantic model.
  """

  alias Catalyst.Runtime.{
    Context,
    Explanation,
    Generation,
    Generations,
    Graph,
    ReadModel,
    Resolution,
    Resolver,
    RunEngine,
    SessionEngine,
    ServiceKey
  }

  @doc "Resolve arbitrary claims through the pure Runtime Graph resolver."
  @spec resolve(
          [Catalyst.Runtime.Claim.t()],
          ServiceKey.t(),
          Context.t() | map() | keyword(),
          keyword()
        ) ::
          {:ok, Resolution.t()} | {:error, Explanation.t()}
  defdelegate resolve(claims, key, context, opts \\ []), to: Resolver

  @doc "Explain arbitrary claim resolution without performing side effects."
  @spec explain(
          [Catalyst.Runtime.Claim.t()],
          ServiceKey.t(),
          Context.t() | map() | keyword(),
          keyword()
        ) ::
          Explanation.t()
  defdelegate explain(claims, key, context, opts \\ []), to: Resolver

  @doc "Capture the currently observable graph from every registered host source."
  @spec snapshot(Context.t() | map() | keyword()) :: Graph.t()
  defdelegate snapshot(context \\ %{}), to: ReadModel

  @doc "Explain one service key from a freshly captured aggregate graph."
  @spec explain(ServiceKey.t(), Context.t() | map() | keyword()) :: Explanation.t()
  def explain(%ServiceKey{} = key, context) do
    graph = snapshot(context)
    Resolver.explain(graph.claims, key, graph.context)
  end

  @doc "Resolve the effective run engine through the Runtime Graph adapter."
  @spec resolve_run_engine(keyword() | map(), Context.t() | map() | keyword()) ::
          {:ok, RunEngine.resolved()} | {:error, term()}
  defdelegate resolve_run_engine(opts, context \\ %{}), to: RunEngine, as: :resolve

  @doc "Explain the effective run engine without starting a session run."
  @spec explain_run_engine(keyword() | map(), Context.t() | map() | keyword()) ::
          {:ok, Explanation.t()} | {:error, term()}
  defdelegate explain_run_engine(opts, context \\ %{}), to: RunEngine, as: :explain

  @doc "Resolve the effective session engine for a newly started session."
  @spec resolve_session_engine(Context.t() | map() | keyword()) ::
          {:ok, Resolution.t()} | {:error, term()}
  defdelegate resolve_session_engine(context \\ %{}), to: SessionEngine, as: :resolve

  @doc "Explain the effective session engine without starting a session."
  @spec explain_session_engine(Context.t() | map() | keyword()) :: Explanation.t()
  defdelegate explain_session_engine(context \\ %{}), to: SessionEngine, as: :explain

  @doc "Return the active managed runtime generation."
  @spec active_generation() :: Generation.t() | nil
  defdelegate active_generation(), to: Generations, as: :active

  @doc "List retained managed generation lifecycle records."
  @spec generations() :: [Generation.t()]
  defdelegate generations(), to: Generations, as: :list
end
