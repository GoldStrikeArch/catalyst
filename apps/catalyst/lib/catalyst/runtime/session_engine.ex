defmodule Catalyst.Runtime.SessionEngine do
  @moduledoc """
  Runtime Graph adapter for the session-lifetime semantic engine.

  Resolution is pinned when a `Catalyst.Session.Server` starts. Activating a new
  claim affects new sessions only; existing sessions retain their exact managed
  generation until they terminate.
  """

  alias Catalyst.Contracts.SessionEngine.{V1, V2}
  alias Catalyst.Runtime.{Claim, Context, ContractRef, ExtensionPoints}

  alias Catalyst.Runtime.{
    Handle,
    ImplementationRef,
    Resolution,
    Resolver,
    Scope,
    Service,
    ServiceKey
  }

  alias Catalyst.Runtime.Transport
  alias Catalyst.Session.{Effect, EngineState, EventEnvelope, StateCapsule}

  @doc "Resolve the effective default session engine."
  @spec resolve(Context.t() | map() | keyword()) ::
          {:ok, Resolution.t()} | {:error, term()}
  def resolve(context \\ %{}) do
    context = Context.host(context)

    case Resolver.resolve(claims(), key(), context) do
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
  def pin(%Resolution{} = resolution, owner \\ self()) when is_pid(owner),
    do: Service.acquire(resolution, owner)

  @doc "Release a pinned session-engine handle."
  @spec release(Handle.t()) :: :ok
  def release(%Handle{} = handle), do: Handle.release(handle)

  @doc "Initialize implementation-private state for a pinned engine."
  @spec initialize(Handle.t(), map()) :: {:ok, term()} | {:error, term()}
  def initialize(%Handle{} = handle, context) when is_map(context) do
    case contract_version(handle) do
      1 ->
        {:ok, nil}

      2 ->
        handle
        |> Transport.invoke(:init, [context])
        |> validate_initialize()
    end
  rescue
    error -> {:error, {:session_engine_init_exception, error}}
  catch
    kind, reason -> {:error, {:session_engine_init_exception, {kind, reason}}}
  end

  @doc "Apply one pure semantic command through the pinned engine."
  @spec command(Handle.t(), V2.command(), EngineState.t(), term()) ::
          {:ok, EngineState.t(), term(), [Effect.t()], term()} | {:error, term()}
  def command(%Handle{} = handle, command, %EngineState{} = state, private_state) do
    result =
      case contract_version(handle) do
        1 -> Catalyst.Session.DefaultEngineV2.command(command, state, private_state)
        2 -> Transport.invoke(handle, :command, [command, state, private_state])
      end

    validate_command(result)
  rescue
    error -> {:error, {:session_engine_command_exception, error}}
  catch
    kind, reason -> {:error, {:session_engine_command_exception, {kind, reason}}}
  end

  @doc "Fold one event and return private state plus bounded host effects."
  @spec transition(Handle.t(), EventEnvelope.t(), EngineState.t(), term()) ::
          {:ok, EngineState.t(), term(), [Effect.t()]} | {:error, term()}
  def transition(
        %Handle{} = handle,
        %EventEnvelope{} = envelope,
        %EngineState{} = state,
        private_state
      ) do
    result =
      case contract_version(handle) do
        1 ->
          {:ok, Transport.invoke(handle, :event, [envelope, state]), private_state, []}

        2 ->
          Transport.invoke(handle, :event, [envelope, state, private_state])
      end

    validate_transition(result)
  rescue
    error -> {:error, {:session_engine_event_exception, error}}
  catch
    kind, reason -> {:error, {:session_engine_event_exception, {kind, reason}}}
  end

  @doc "Fold one versioned event through the pinned engine target."
  @spec event(Handle.t(), EventEnvelope.t(), EngineState.t()) :: EngineState.t()
  def event(%Handle{} = handle, %EventEnvelope{} = envelope, %EngineState{} = state) do
    case transition(handle, envelope, state, %{}) do
      {:ok, %EngineState{} = transitioned, _private_state, []} ->
        transitioned

      {:ok, %EngineState{}, _private_state, effects} ->
        raise "uninterpreted effects: #{inspect(effects)}"

      {:error, reason} ->
        raise "session engine event failed: #{inspect(reason)}"
    end
  end

  @doc "Build orphan repair results through the pinned engine target."
  @spec aborted_tool_results(Handle.t(), EngineState.t(), term()) ::
          [Catalyst.Message.ToolResult.t()]
  def aborted_tool_results(%Handle{} = handle, %EngineState{} = state, reason) do
    aborted_tool_results(handle, state, nil, reason)
  end

  @doc "Build orphan repair results using implementation-private state."
  @spec aborted_tool_results(Handle.t(), EngineState.t(), term(), term()) ::
          [Catalyst.Message.ToolResult.t()]
  def aborted_tool_results(%Handle{} = handle, %EngineState{} = state, private_state, reason) do
    case contract_version(handle) do
      1 -> Transport.invoke(handle, :aborted_tool_results, [state, reason])
      2 -> Transport.invoke(handle, :aborted_tool_results, [state, private_state, reason])
    end
  end

  @doc "Build a failure message through the pinned engine target."
  @spec failure_message(Handle.t(), EngineState.t(), term()) :: Catalyst.Message.Assistant.t()
  def failure_message(%Handle{} = handle, %EngineState{} = state, reason) do
    failure_message(handle, state, nil, reason)
  end

  @doc "Build a failure message using implementation-private state."
  @spec failure_message(Handle.t(), EngineState.t(), term(), term()) ::
          Catalyst.Message.Assistant.t()
  def failure_message(%Handle{} = handle, %EngineState{} = state, private_state, reason) do
    case contract_version(handle) do
      1 -> Transport.invoke(handle, :failure_message, [state, reason])
      2 -> Transport.invoke(handle, :failure_message, [state, private_state, reason])
    end
  end

  @doc "Snapshot engine-owned state through a pinned source handle."
  @spec snapshot(Handle.t(), EngineState.t()) :: {:ok, V1.snapshot()} | {:error, term()}
  def snapshot(%Handle{} = handle, %EngineState{} = state) do
    case contract_version(handle) do
      1 ->
        with :ok <- ensure_handoff_callback(handle, :snapshot),
             result <-
               safe_handoff_callback(:snapshot, fn ->
                 Transport.invoke(handle, :snapshot, [state])
               end) do
          validate_snapshot(result)
        end

      2 ->
        with {:ok, capsule} <- snapshot_binding(handle, state, %{}) do
          {:ok, %{version: capsule.state_version, payload: capsule.payload}}
        end
    end
  end

  @doc "Restore engine-owned state through a pinned target handle."
  @spec restore(Handle.t(), V1.snapshot()) :: {:ok, EngineState.t()} | {:error, term()}
  def restore(%Handle{} = handle, snapshot) do
    case contract_version(handle) do
      1 ->
        restore_v1(handle, snapshot)

      2 ->
        with {:ok, capsule} <-
               StateCapsule.new(
                 V2.ref(),
                 Map.get(snapshot, :version, 1),
                 handle.logical_implementation,
                 Map.get(snapshot, :payload, snapshot)
               ),
             {:ok, state, _private} <- restore_binding(handle, capsule) do
          {:ok, state}
        end
    end
  end

  @doc "Create a bounded handoff capsule from semantic and private engine state."
  @spec snapshot_binding(Handle.t(), EngineState.t(), term()) ::
          {:ok, StateCapsule.t()} | {:error, term()}
  def snapshot_binding(%Handle{} = handle, %EngineState{} = state, private_state) do
    with {:ok, state_version, payload} <- snapshot_payload(handle, state, private_state) do
      StateCapsule.new(
        handle.resolution.contract,
        state_version,
        handle.logical_implementation,
        payload
      )
    end
  end

  @doc "Restore and verify semantic plus private state through a pinned target."
  @spec restore_binding(Handle.t(), StateCapsule.t()) ::
          {:ok, EngineState.t(), term()} | {:error, term()}
  def restore_binding(%Handle{} = handle, %StateCapsule{} = capsule) do
    with :ok <- StateCapsule.verify(capsule) do
      case contract_version(handle) do
        1 -> restore_v1_binding(handle, capsule)
        2 -> restore_v2_binding(handle, capsule)
      end
    end
  end

  @doc "Explain the effective session engine without starting a session."
  @spec explain(Context.t() | map() | keyword()) :: Catalyst.Runtime.Explanation.t()
  def explain(context \\ %{}) do
    Resolver.explain(claims(), key(), Context.host(context))
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
    |> Enum.filter(
      &(ContractRef.compatible?(&1.contract, V1.ref()) or
          ContractRef.compatible?(&1.contract, V2.ref()))
    )
  end

  defp builtin_claim do
    %Claim{
      key: key(),
      contract: V2.ref(),
      implementation: Catalyst.Session.DefaultEngineV2,
      owner: :builtin,
      scope: Scope.global(),
      priority: 0,
      binding: {:pin, :session},
      provenance: :builtin,
      metadata: %{}
    }
  end

  defp contract_version(%Handle{
         resolution: %Resolution{contract: %ContractRef{version: version}}
       }),
       do: version

  defp validate_initialize({:ok, private_state}), do: {:ok, private_state}
  defp validate_initialize({:error, _reason} = error), do: error

  defp validate_initialize(invalid),
    do: {:error, {:invalid_session_engine_result, :init, invalid}}

  defp validate_command({:ok, %EngineState{} = state, private_state, effects, reply})
       when is_list(effects) do
    with :ok <- validate_effects(effects) do
      {:ok, state, private_state, effects, reply}
    end
  end

  defp validate_command({:error, _reason} = error), do: error

  defp validate_command(invalid),
    do: {:error, {:invalid_session_engine_result, :command, invalid}}

  defp validate_transition({:ok, %EngineState{} = state, private_state, effects})
       when is_list(effects) do
    with :ok <- validate_effects(effects) do
      {:ok, state, private_state, effects}
    end
  end

  defp validate_transition({:error, _reason} = error), do: error

  defp validate_transition(invalid),
    do: {:error, {:invalid_session_engine_result, :event, invalid}}

  defp validate_effects(effects) do
    Enum.reduce_while(effects, :ok, fn
      %Effect{} = effect, :ok ->
        case Effect.validate(effect) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      invalid, :ok ->
        {:halt, {:error, {:invalid_session_effect, invalid}}}
    end)
  end

  defp snapshot_payload(%Handle{} = handle, %EngineState{} = state, private_state) do
    case contract_version(handle) do
      1 ->
        with :ok <- ensure_handoff_callback(handle, :snapshot),
             {:ok, %{version: version, payload: payload}} <-
               safe_handoff_callback(:snapshot, fn ->
                 Transport.invoke(handle, :snapshot, [state])
               end) do
          {:ok, version, payload}
        end

      2 ->
        with {:ok, state_version} <- state_version(handle),
             {:ok, payload} <-
               safe_handoff_callback(:snapshot, fn ->
                 Transport.invoke(handle, :snapshot, [state, private_state])
               end) do
          {:ok, state_version, payload}
        end
    end
  end

  defp state_version(%Handle{} = handle) do
    case Transport.invoke(handle, :state_version, []) do
      version when is_integer(version) and version > 0 -> {:ok, version}
      invalid -> {:error, {:invalid_session_engine_state_version, invalid}}
    end
  end

  defp restore_v1(%Handle{} = handle, snapshot) do
    with :ok <- ensure_handoff_callback(handle, :restore),
         result <-
           safe_handoff_callback(:restore, fn ->
             Transport.invoke(handle, :restore, [snapshot])
           end) do
      validate_restored_state(result)
    end
  end

  defp restore_v1_binding(%Handle{} = handle, %StateCapsule{} = capsule) do
    snapshot = %{version: capsule.state_version, payload: capsule.payload}

    with {:ok, state} <- restore_v1(handle, snapshot) do
      {:ok, state, nil}
    end
  end

  defp restore_v2_binding(%Handle{} = handle, %StateCapsule{} = capsule) do
    result =
      safe_handoff_callback(:restore, fn ->
        Transport.invoke(handle, :restore, [capsule])
      end)

    with {:ok, %EngineState{} = state, private_state} <- validate_v2_restore(result),
         :ok <-
           safe_handoff_callback(:verify_handoff, fn ->
             Transport.invoke(handle, :verify_handoff, [capsule, state, private_state])
           end) do
      {:ok, state, private_state}
    end
  end

  defp validate_v2_restore({:ok, %EngineState{} = state, private_state}),
    do: {:ok, state, private_state}

  defp validate_v2_restore({:error, _reason} = error), do: error

  defp validate_v2_restore(invalid),
    do: {:error, {:invalid_session_engine_handoff_result, :restore, invalid}}

  defp safe_handoff_callback(operation, callback) do
    case callback.() do
      :ok -> :ok
      {:ok, _value} = success -> success
      {:ok, _value, _private_state} = success -> success
      {:error, _reason} = error -> error
      invalid -> {:error, {:invalid_session_engine_handoff_result, operation, invalid}}
    end
  rescue
    error -> {:error, {:session_engine_handoff_exception, operation, error}}
  catch
    kind, reason -> {:error, {:session_engine_handoff_exception, operation, {kind, reason}}}
  end

  defp ensure_handoff_callback(
         %Handle{
           resolution: %Resolution{
             claim: %Claim{implementation: %ImplementationRef{transport: :process}}
           }
         },
         _callback
       ),
       do: :ok

  defp ensure_handoff_callback(%Handle{implementation: implementation}, callback) do
    case Code.ensure_loaded(implementation) do
      {:module, ^implementation} ->
        ensure_exported_handoff_callback(implementation, callback)

      {:error, reason} ->
        {:error, {:session_engine_handoff_module_unavailable, implementation, reason}}
    end
  end

  defp ensure_exported_handoff_callback(implementation, callback) do
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
