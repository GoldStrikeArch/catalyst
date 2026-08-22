defmodule Catalyst.Runtime.SessionFactory do
  @moduledoc """
  Runtime Graph adapter for managed local session construction.

  This seam selects an OTP child spec for a new local session. Registry lookup,
  commands, and remote or sovereign session transport remain owned by the
  existing session host.
  """

  alias Catalyst.Contracts.SessionFactory.V1

  alias Catalyst.Runtime.{
    Claim,
    Context,
    ContractRef,
    ExtensionPoints,
    Generations,
    Handle,
    ImplementationRef,
    Leases,
    Resolution,
    Resolver,
    Scope,
    ServiceKey,
    Transport
  }

  @doc "Resolve and pin the effective factory for one new local session."
  @spec resolve_and_pin(Context.t() | map() | keyword(), pid()) ::
          {:ok, Handle.t()} | {:error, term()}
  def resolve_and_pin(context, owner \\ self()) when is_pid(owner),
    do: resolve_and_pin(context, owner, 1)

  @doc "Build a temporary local child spec through a pinned factory."
  @spec child_spec(Handle.t(), keyword()) ::
          {:ok, Supervisor.child_spec()} | {:error, term()}
  def child_spec(%Handle{} = handle, opts) when is_list(opts) do
    opts = Keyword.put(opts, :session_factory_handle, handle)

    case invoke(handle, opts) do
      {:ok, child_spec} -> normalize_child_spec(child_spec)
      {:error, _reason} = error -> error
      invalid -> {:error, {:invalid_session_factory_result, invalid}}
    end
  rescue
    error -> {:error, {:session_factory_exception, error}}
  catch
    kind, reason -> {:error, {:session_factory_exception, {kind, reason}}}
  end

  def child_spec(%Handle{}, opts), do: {:error, {:invalid_session_options, opts}}

  @doc "Transfer a pinned managed factory handle to its started session process."
  @spec adopt(Handle.t(), pid()) :: {:ok, Handle.t()} | {:error, term()}
  def adopt(%Handle{lease: nil} = handle, owner) when is_pid(owner), do: {:ok, handle}

  def adopt(%Handle{lease: lease} = handle, owner) when is_pid(owner) do
    with {:ok, transferred} <- Leases.transfer(lease, owner) do
      {:ok, %{handle | lease: transferred}}
    end
  end

  @doc "Release a pinned factory handle."
  @spec release(Handle.t() | nil) :: :ok
  def release(nil), do: :ok
  def release(%Handle{} = handle), do: Handle.release(handle)

  @doc "Resolve the effective local session factory."
  @spec resolve(Context.t() | map() | keyword()) :: {:ok, Resolution.t()} | {:error, term()}
  def resolve(context \\ %{}) do
    context = Context.host(context)

    case Resolver.resolve(claims(), key(), context, contract: V1.ref()) do
      {:ok, resolution} -> {:ok, resolution}
      {:error, %{status: {:error, reason}}} -> {:error, {:session_factory_resolution, reason}}
    end
  end

  @doc "Explain the effective local session factory."
  @spec explain(Context.t() | map() | keyword()) :: Catalyst.Runtime.Explanation.t()
  def explain(context \\ %{}),
    do: Resolver.explain(claims(), key(), Context.host(context), contract: V1.ref())

  @doc "Export managed and built-in local session-factory claims."
  @spec claims() :: [Claim.t()]
  def claims, do: managed_claims() ++ [builtin_claim()]

  @doc false
  @spec unmanaged_claims() :: [Claim.t()]
  def unmanaged_claims, do: [builtin_claim()]

  @doc "Return the default session-factory service key."
  @spec key() :: ServiceKey.t()
  def key, do: ServiceKey.new!("agent", "session_factory", "default")

  @doc "Project a factory resolution into serializable session diagnostics."
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

  defp resolve_and_pin(context, owner, retries) do
    with {:ok, resolution} <- resolve(context),
         result <- pin(resolution, owner) do
      case result do
        {:error, {:stale_runtime_generation, _requested, _active}} when retries > 0 ->
          resolve_and_pin(context, owner, retries - 1)

        other ->
          other
      end
    end
  end

  defp pin(%Resolution{} = resolution, owner) do
    case Map.get(resolution.claim.metadata, :runtime_generation) do
      nil -> {:ok, Handle.new(resolution, nil)}
      _generation -> acquire_handle(resolution, owner)
    end
  end

  defp acquire_handle(resolution, owner) do
    with {:ok, lease} <- Generations.acquire_lease(resolution, owner) do
      {:ok, Handle.new(resolution, lease)}
    end
  end

  defp invoke(%Handle{} = handle, opts) do
    Transport.invoke(handle, :child_spec, [opts])
  end

  defp normalize_child_spec(child_spec) do
    # Manager-started sessions remain temporary even when a factory returns a
    # different restart policy: a poisoned factory/store must not exhaust the
    # shared DynamicSupervisor's restart budget and kill sibling sessions.
    {:ok, Supervisor.child_spec(child_spec, restart: :temporary)}
  rescue
    error -> {:error, {:invalid_session_child_spec, error}}
  end

  defp managed_claims do
    ExtensionPoints.list_claims()
    |> Enum.filter(&(&1.key == key()))
    |> Enum.filter(&ContractRef.compatible?(&1.contract, V1.ref()))
  end

  defp builtin_claim do
    %Claim{
      key: key(),
      contract: V1.ref(),
      implementation: Catalyst.Session.DefaultSessionFactory,
      owner: :builtin,
      scope: Scope.global(),
      priority: 0,
      binding: {:pin, :session},
      provenance: :builtin,
      metadata: %{}
    }
  end
end
