defmodule Catalyst.Runtime.RunEngine do
  @moduledoc """
  Runtime Graph adapter for the existing workflow selection system.

  The workflow registry remains the authoritative write path in phase one.
  This adapter projects its effective selection into an ordinary runtime claim,
  resolves that claim through the generic resolver, and preserves the complete
  workflow selection payload for templates and providerless workflows.
  """

  alias Catalyst.Contracts.RunEngine.V1
  alias Catalyst.Runtime.{Claim, Context, Resolution, Resolver, Scope, ServiceKey}
  alias Catalyst.Workflow.Registry

  @type resolved :: %{selection: Registry.selection(), resolution: Resolution.t()}

  @doc "Resolve and logically pin the effective run engine for one run."
  @spec resolve(keyword() | map(), Context.t() | map() | keyword()) ::
          {:ok, resolved()} | {:error, term()}
  def resolve(opts, context \\ %{}) do
    context = Context.new(context)

    with {:ok, selection} <- Registry.resolve(opts),
         claims = execution_claims(selection, context),
         key = key(selection),
         {:ok, resolution} <- Resolver.resolve(claims, key, context, contract: V1.ref()) do
      {:ok, %{selection: selection, resolution: resolution}}
    else
      {:error, %{status: {:error, reason}}} -> {:error, {:run_engine_resolution, reason}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Explain the effective run-engine selection without starting a run."
  @spec explain(keyword() | map(), Context.t() | map() | keyword()) ::
          {:ok, Catalyst.Runtime.Explanation.t()} | {:error, term()}
  def explain(opts, context \\ %{}) do
    context = Context.new(context)

    with {:ok, selection, layers} <- Registry.resolve_with_layers(opts) do
      claims = Enum.map(layers, &claim(&1, context))
      {:ok, Resolver.explain(claims, key(selection), context, contract: V1.ref())}
    end
  end

  @doc "Export every claim in the selected workflow slot's current precedence chain."
  @spec claims(keyword() | map(), Context.t() | map() | keyword()) ::
          {:ok, [Claim.t()]} | {:error, term()}
  def claims(opts, context \\ %{}) do
    context = Context.new(context)

    with {:ok, _selection, layers} <- Registry.resolve_with_layers(opts) do
      {:ok, Enum.map(layers, &claim(&1, context))}
    end
  end

  @doc "Export claims for every currently selectable workflow slot."
  @spec all_claims(Context.t() | map() | keyword()) :: [Claim.t()]
  def all_claims(context \\ %{}) do
    context = Context.new(context)

    Registry.list()
    |> Enum.flat_map(fn selection ->
      case claims(selection_opts(selection), context) do
        {:ok, claims} -> claims
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq_by(&Claim.stable_key/1)
  end

  @doc "Return the run-engine service key for a selection slot."
  @spec key(Registry.selection() | String.t() | :default | :loop) :: ServiceKey.t()
  def key(%{name: name}), do: key(name)
  def key(:default), do: ServiceKey.new!("agent", "run_engine", "default")
  def key(:loop), do: ServiceKey.new!("agent", "run_engine", "direct")
  def key(name) when is_binary(name), do: ServiceKey.new!("agent", "run_engine", named_slot(name))

  @doc "Build the run-engine service key accepted by the extension workflow API."
  @spec service_key(String.t() | :default) :: {:ok, ServiceKey.t()} | {:error, term()}
  def service_key(:default), do: ServiceKey.new("agent", "run_engine", "default")

  def service_key(name) when is_binary(name) and byte_size(name) > 0,
    do: ServiceKey.new("agent", "run_engine", named_slot(name))

  def service_key(name), do: {:error, {:invalid_workflow_name, name}}

  @doc false
  @spec workflow_name(ServiceKey.t()) :: {:ok, String.t() | :default} | {:error, term()}
  def workflow_name(%ServiceKey{namespace: "agent", name: "run_engine", slot: "default"}),
    do: {:ok, :default}

  def workflow_name(%ServiceKey{
        namespace: "agent",
        name: "run_engine",
        slot: "named:" <> name
      })
      when byte_size(name) > 0,
      do: {:ok, name}

  def workflow_name(%ServiceKey{} = key),
    do: {:error, {:invalid_run_engine_service_key, ServiceKey.to_wire(key)}}

  @doc "Project a phase-one resolution into serializable run diagnostics."
  @spec metadata(Resolution.t()) :: map()
  def metadata(%Resolution{} = resolution) do
    claim = resolution.claim

    %{
      service: ServiceKey.to_wire(resolution.key),
      contract: %{id: resolution.contract.id, version: resolution.contract.version},
      snapshot_id: resolution.snapshot_id,
      owner: claim.owner,
      scope: claim.scope.constraints,
      binding: claim.binding,
      provenance: claim.provenance,
      implementation: claim.implementation
    }
  end

  defp claim(selection, context) do
    %Claim{
      key: key(selection),
      contract: V1.ref(),
      implementation: selection.module,
      owner: owner(selection.source, context),
      scope: scope(selection.source, context),
      priority: priority(selection.source),
      binding: {:pin, :run},
      provenance: selection.source,
      metadata: %{selection: selection}
    }
  end

  defp execution_claims(%{name: :default, source: source} = selection, context)
       when source != :builtin,
       do: [claim(selection, context), claim(builtin_selection(), context)]

  defp execution_claims(selection, context), do: [claim(selection, context)]

  defp builtin_selection,
    do: %{name: :default, module: Catalyst.Agent.Loop, source: :builtin}

  defp owner({:session, :loop}, %Context{session_id: session_id}),
    do: {:session, session_id || :unknown}

  defp owner({:runtime, owner, _key}, _context), do: owner
  defp owner({:application, _source}, _context), do: :application
  defp owner({:template, _metadata}, _context), do: :workflow_store
  defp owner(:builtin, _context), do: :builtin

  defp scope({:session, :loop}, %Context{session_id: session_id}) when is_binary(session_id),
    do: Scope.new!(session_id: session_id)

  defp scope(_source, _context), do: Scope.global()

  defp priority({:session, :loop}), do: 1_000
  defp priority({:runtime, _owner, _key}), do: 800
  defp priority({:application, {:workflows, _name}}), do: 600
  defp priority({:application, {:acp_agent, _id}}), do: 550
  defp priority({:template, _metadata}), do: 500
  defp priority({:application, :agent_loop}), do: 400
  defp priority(:builtin), do: 0

  defp selection_opts(%{name: :default}), do: []
  defp selection_opts(%{name: name}), do: [workflow: name]

  defp named_slot(name), do: "named:" <> name
end
