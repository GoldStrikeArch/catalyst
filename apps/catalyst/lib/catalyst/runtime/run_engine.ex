defmodule Catalyst.Runtime.RunEngine do
  @moduledoc """
  Runtime Graph adapter for the existing workflow selection system.

  The workflow registry remains the authoritative write path in phase one.
  This adapter projects its effective selection into an ordinary runtime claim,
  resolves that claim through the generic resolver, and preserves the complete
  workflow selection payload for templates and providerless workflows.
  """

  alias Catalyst.Contracts.RunEngine.V1

  alias Catalyst.Runtime.{
    Claim,
    Context,
    ContractRef,
    ExtensionPoints,
    Generations,
    Handle,
    ImplementationRef,
    Resolution,
    Resolver,
    Scope,
    ServiceKey
  }

  alias Catalyst.Workflow.Registry
  alias Catalyst.Workflow

  @type resolved :: %{
          optional(:handle) => Handle.t(),
          selection: Registry.selection(),
          resolution: Resolution.t()
        }

  @doc "Resolve and logically pin the effective run engine for one run."
  @spec resolve(keyword() | map(), Context.t() | map() | keyword()) ::
          {:ok, resolved()} | {:error, term()}
  def resolve(opts, context \\ %{}) do
    context = Context.host(context)

    with {:ok, key, claims} <- resolution_claims(opts, context),
         {:ok, resolution} <- Resolver.resolve(claims, key, context, contract: V1.ref()),
         {:ok, selection} <- selection(resolution.claim, key) do
      {:ok, %{selection: selection, resolution: resolution}}
    else
      {:error, %{status: {:error, reason}}} -> {:error, {:run_engine_resolution, reason}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Acquire the managed-generation lease for a resolved run engine."
  @spec pin(resolved(), pid()) :: {:ok, resolved()} | {:error, term()}
  def pin(%{resolution: %Resolution{} = resolution} = resolved, owner \\ self())
      when is_pid(owner) do
    case Map.get(resolution.claim.metadata, :runtime_generation) do
      nil ->
        {:ok, put_handle(resolved, resolution, nil)}

      _generation ->
        with {:ok, lease} <- Generations.acquire_lease(resolution, owner) do
          {:ok, put_handle(resolved, resolution, lease)}
        end
    end
  end

  @doc "Release a previously pinned run engine."
  @spec release(resolved()) :: :ok
  def release(%{handle: %Handle{} = handle}), do: Handle.release(handle)
  def release(_unmanaged_or_unpinned), do: :ok

  @doc "Invoke a pinned run-engine target through its declared transport."
  @spec invoke(Handle.t(), [Catalyst.Message.t()], map(), map(), Workflow.emitter()) ::
          Workflow.result()
  def invoke(%Handle{} = handle, prompts, context, config, emit) do
    case ImplementationRef.transport(handle.resolution.claim.implementation) do
      :local -> handle.implementation.run(prompts, context, config, emit)
    end
  end

  @doc "Explain the effective run-engine selection without starting a run."
  @spec explain(keyword() | map(), Context.t() | map() | keyword()) ::
          {:ok, Catalyst.Runtime.Explanation.t()} | {:error, term()}
  def explain(opts, context \\ %{}) do
    context = Context.host(context)

    with {:ok, key, claims} <- resolution_claims(opts, context) do
      {:ok, Resolver.explain(claims, key, context, contract: V1.ref())}
    end
  end

  @doc "Export every claim in the selected workflow slot's current precedence chain."
  @spec claims(keyword() | map(), Context.t() | map() | keyword()) ::
          {:ok, [Claim.t()]} | {:error, term()}
  def claims(opts, context \\ %{}) do
    context = Context.host(context)

    with {:ok, _key, claims} <- resolution_claims(opts, context) do
      {:ok, claims}
    end
  end

  @doc "Export claims for every currently selectable workflow slot."
  @spec all_claims(Context.t() | map() | keyword()) :: [Claim.t()]
  def all_claims(context \\ %{}) do
    context = Context.host(context)

    Registry.list()
    |> Enum.flat_map(fn selection ->
      case claims(selection_opts(selection), context) do
        {:ok, claims} -> claims
        {:error, _reason} -> []
      end
    end)
    |> Kernel.++(managed_claims())
    |> Enum.uniq_by(&Claim.stable_key/1)
  end

  @doc false
  @spec unmanaged_claims(Context.t() | map() | keyword()) :: [Claim.t()]
  def unmanaged_claims(context \\ %{}) do
    context
    |> all_claims()
    |> Enum.reject(&match?({:manifest, _id, _version, _declaration}, &1.provenance))
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

  def workflow_name(%ServiceKey{namespace: "agent", name: "run_engine", slot: "direct"}),
    do: {:ok, :loop}

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

    metadata = %{
      service: ServiceKey.to_wire(resolution.key),
      contract: %{id: resolution.contract.id, version: resolution.contract.version},
      snapshot_id: resolution.snapshot_id,
      owner: claim.owner,
      scope: claim.scope.constraints,
      binding: claim.binding,
      provenance: claim.provenance,
      implementation: ImplementationRef.logical(claim.implementation)
    }

    case Map.get(claim.metadata, :runtime_generation) do
      nil -> metadata
      generation -> Map.put(metadata, :generation, generation)
    end
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

  defp resolution_claims(opts, context) do
    with {:ok, key} <- requested_key(opts),
         managed = managed_claims(key),
         {:ok, legacy} <- legacy_claims(opts, context, managed) do
      {:ok, key, managed ++ legacy}
    end
  end

  defp legacy_claims(opts, context, managed) do
    case Registry.resolve_with_layers(opts) do
      {:ok, _selection, layers} ->
        {:ok, Enum.map(layers, &claim(&1, context))}

      {:error, {:unknown_workflow, _name}} when managed != [] ->
        {:ok, []}

      {:error, _reason} = error ->
        error
    end
  end

  defp managed_claims do
    ExtensionPoints.list_claims()
    |> Enum.filter(&ContractRef.compatible?(&1.contract, V1.ref()))
  end

  defp managed_claims(key) do
    managed_claims()
    |> Enum.filter(&(&1.key == key))
  end

  defp requested_key(opts) when is_list(opts) do
    requested_key(Keyword.get(opts, :loop), Keyword.get(opts, :workflow))
  end

  defp requested_key(opts) when is_map(opts) do
    requested_key(Map.get(opts, :loop), Map.get(opts, :workflow))
  end

  defp requested_key(opts),
    do: {:error, {:invalid_configuration, :workflow_options, opts}}

  defp requested_key(loop, _workflow) when not is_nil(loop), do: {:ok, key(:loop)}
  defp requested_key(_loop, workflow) when workflow in [nil, :default], do: {:ok, key(:default)}

  defp requested_key(_loop, workflow) when is_binary(workflow) and byte_size(workflow) > 0,
    do: service_key(workflow)

  defp requested_key(_loop, workflow),
    do: {:error, {:invalid_configuration, {:option, :workflow}, workflow}}

  defp selection(%Claim{metadata: %{selection: selection}}, _key), do: {:ok, selection}

  defp selection(%Claim{} = claim, key) do
    with {:ok, name} <- workflow_name(key) do
      generation = Map.get(claim.metadata, :runtime_generation, "legacy")

      {:ok,
       %{
         name: name,
         module: ImplementationRef.target(claim.implementation),
         logical_module: ImplementationRef.logical(claim.implementation),
         source: {:generation, generation, claim.owner}
       }}
    end
  end

  defp owner({:session, :loop}, %Context{session_id: session_id}),
    do: {:session, session_id || :unknown}

  defp owner({:runtime, owner, _key}, _context), do: owner
  defp owner({:generation, _generation, owner}, _context), do: owner
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

  defp put_handle(resolved, resolution, lease),
    do: Map.put(resolved, :handle, Handle.new(resolution, lease))

  defp named_slot(name), do: "named:" <> name
end
