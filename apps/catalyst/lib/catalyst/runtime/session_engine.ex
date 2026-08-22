defmodule Catalyst.Runtime.SessionEngine do
  @moduledoc """
  Runtime Graph adapter for the session-lifetime semantic engine.

  Resolution is pinned when a `Catalyst.Session.Server` starts. Activating a new
  claim affects new sessions only; existing sessions retain their exact managed
  generation until they terminate.
  """

  alias Catalyst.Contracts.SessionEngine.V1
  alias Catalyst.Runtime.{Claim, Context, ContractRef, ExtensionPoints, Generations}

  alias Catalyst.Runtime.{Handle, ImplementationRef, Resolution, Resolver, Scope, ServiceKey}
  alias Catalyst.Session.{EngineState, EventEnvelope}

  @doc "Resolve the effective default session engine."
  @spec resolve(Context.t() | map() | keyword()) ::
          {:ok, Resolution.t()} | {:error, term()}
  def resolve(context \\ %{}) do
    context = Context.new(context)

    case Resolver.resolve(claims(), key(), context, contract: V1.ref()) do
      {:ok, resolution} -> {:ok, resolution}
      {:error, %{status: {:error, reason}}} -> {:error, {:session_engine_resolution, reason}}
    end
  end

  @doc "Resolve and acquire a session-owned managed-generation lease."
  @spec resolve_and_pin(Context.t() | map() | keyword(), pid()) ::
          {:ok, Handle.t()} | {:error, term()}
  def resolve_and_pin(context, owner \\ self()) when is_pid(owner) do
    resolve_and_pin(context, owner, 1)
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

  @doc "Acquire the managed-generation lease for a resolved session engine."
  @spec pin(Resolution.t(), pid()) :: {:ok, Handle.t()} | {:error, term()}
  def pin(%Resolution{} = resolution, owner \\ self()) when is_pid(owner) do
    case Map.get(resolution.claim.metadata, :runtime_generation) do
      nil -> {:ok, Handle.new(resolution, nil)}
      _generation -> acquire_handle(resolution, owner)
    end
  end

  @doc "Release a pinned session-engine handle."
  @spec release(Handle.t()) :: :ok
  def release(%Handle{} = handle), do: Handle.release(handle)

  @doc "Fold one versioned event through the pinned engine target."
  @spec event(Handle.t(), EventEnvelope.t(), EngineState.t()) :: EngineState.t()
  def event(%Handle{} = handle, %EventEnvelope{} = envelope, %EngineState{} = state) do
    case ImplementationRef.transport(handle.resolution.claim.implementation) do
      :local ->
        %EngineState{} = handle.implementation.event(envelope, state)
    end
  end

  @doc "Build orphan repair results through the pinned engine target."
  @spec aborted_tool_results(Handle.t(), EngineState.t(), term()) ::
          [Catalyst.Message.ToolResult.t()]
  def aborted_tool_results(%Handle{} = handle, %EngineState{} = state, reason) do
    case ImplementationRef.transport(handle.resolution.claim.implementation) do
      :local -> handle.implementation.aborted_tool_results(state, reason)
    end
  end

  @doc "Build a failure message through the pinned engine target."
  @spec failure_message(Handle.t(), EngineState.t(), term()) :: Catalyst.Message.Assistant.t()
  def failure_message(%Handle{} = handle, %EngineState{} = state, reason) do
    case ImplementationRef.transport(handle.resolution.claim.implementation) do
      :local -> handle.implementation.failure_message(state, reason)
    end
  end

  @doc "Snapshot engine-owned state through a pinned source handle."
  @spec snapshot(Handle.t(), EngineState.t()) :: {:ok, V1.snapshot()} | {:error, term()}
  def snapshot(%Handle{} = handle, %EngineState{} = state) do
    with :ok <- ensure_handoff_callback(handle, :snapshot),
         result <-
           safe_handoff_callback(:snapshot, fn ->
             case ImplementationRef.transport(handle.resolution.claim.implementation) do
               :local -> handle.implementation.snapshot(state)
             end
           end) do
      validate_snapshot(result)
    end
  end

  @doc "Restore engine-owned state through a pinned target handle."
  @spec restore(Handle.t(), V1.snapshot()) :: {:ok, EngineState.t()} | {:error, term()}
  def restore(%Handle{} = handle, snapshot) do
    with :ok <- ensure_handoff_callback(handle, :restore),
         result <-
           safe_handoff_callback(:restore, fn ->
             case ImplementationRef.transport(handle.resolution.claim.implementation) do
               :local -> handle.implementation.restore(snapshot)
             end
           end) do
      validate_restored_state(result)
    end
  end

  @doc "Explain the effective session engine without starting a session."
  @spec explain(Context.t() | map() | keyword()) :: Catalyst.Runtime.Explanation.t()
  def explain(context \\ %{}) do
    Resolver.explain(claims(), key(), Context.new(context), contract: V1.ref())
  end

  @doc "Export the managed and built-in session-engine claims."
  @spec claims() :: [Claim.t()]
  def claims, do: managed_claims() ++ [builtin_claim()]

  @doc false
  @spec unmanaged_claims() :: [Claim.t()]
  def unmanaged_claims, do: [builtin_claim()]

  @doc "Return the default session-engine service key."
  @spec key() :: ServiceKey.t()
  def key, do: ServiceKey.new!("agent", "session_engine", "default")

  @doc "Project a session-engine resolution into serializable diagnostics."
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

  defp managed_claims do
    ExtensionPoints.list_claims()
    |> Enum.filter(&(&1.key == key()))
    |> Enum.filter(&ContractRef.compatible?(&1.contract, V1.ref()))
  end

  defp builtin_claim do
    %Claim{
      key: key(),
      contract: V1.ref(),
      implementation: Catalyst.Session.DefaultEngine,
      owner: :builtin,
      scope: Scope.global(),
      priority: 0,
      binding: {:pin, :session},
      provenance: :builtin,
      metadata: %{}
    }
  end

  defp acquire_handle(resolution, owner) do
    with {:ok, lease} <- Generations.acquire_lease(resolution, owner) do
      {:ok, Handle.new(resolution, lease)}
    end
  end

  defp safe_handoff_callback(operation, callback) do
    case callback.() do
      {:ok, _value} = success -> success
      {:error, _reason} = error -> error
      invalid -> {:error, {:invalid_session_engine_handoff_result, operation, invalid}}
    end
  rescue
    error -> {:error, {:session_engine_handoff_exception, operation, error}}
  catch
    kind, reason -> {:error, {:session_engine_handoff_exception, operation, {kind, reason}}}
  end

  defp ensure_handoff_callback(%Handle{implementation: implementation}, callback) do
    case function_exported?(implementation, callback, 1) do
      true -> :ok
      false -> {:error, {:session_engine_handoff_not_supported, implementation, callback}}
    end
  end

  defp validate_snapshot({:ok, %{version: version, payload: _payload} = snapshot})
       when is_integer(version) and version > 0,
       do: {:ok, snapshot}

  defp validate_snapshot({:ok, invalid}),
    do: {:error, {:invalid_session_engine_handoff_result, :snapshot, invalid}}

  defp validate_snapshot({:error, _reason} = error), do: error

  defp validate_restored_state({:ok, %EngineState{} = state}), do: {:ok, state}

  defp validate_restored_state({:ok, invalid}),
    do: {:error, {:invalid_session_engine_handoff_result, :restore, invalid}}

  defp validate_restored_state({:error, _reason} = error), do: error
end
