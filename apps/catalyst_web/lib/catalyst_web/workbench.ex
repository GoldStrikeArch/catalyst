defmodule CatalystWeb.Workbench do
  @moduledoc """
  Runtime Graph adapter and guarded invocation boundary for mounted workbenches.

  One resolution is pinned for the lifetime of `CatalystWeb.WorkbenchHostLive`.
  Activating a replacement affects new mounts while existing hosts retain their
  process-owned managed-generation lease.
  """

  alias Catalyst.Contracts.Workbench.V1
  alias Catalyst.Tasks

  alias Catalyst.Runtime.{
    Claim,
    Context,
    ContractRef,
    ExtensionPoints,
    Handle,
    ImplementationRef,
    Resolution,
    Resolver,
    Scope,
    Service,
    ServiceKey,
    Transport
  }

  @default_callback_timeout 1_000
  @max_forms_bytes 2_097_152

  @doc "Resolve and pin the effective default workbench for one LiveView mount."
  @spec resolve_and_pin(Context.t() | map() | keyword(), pid()) ::
          {:ok, Handle.t()} | {:error, term()}
  def resolve_and_pin(context, owner \\ self()) when is_pid(owner) do
    resolve_and_pin(context, owner, 1)
  end

  defp resolve_and_pin(context, owner, retries) do
    with {:ok, resolution} <- resolve(context),
         result <- Service.acquire(resolution, owner) do
      case result do
        {:error, {:stale_runtime_generation, _requested, _active}} when retries > 0 ->
          resolve_and_pin(context, owner, retries - 1)

        other ->
          other
      end
    end
  end

  @doc "Resolve the effective workbench without acquiring a generation lease."
  @spec resolve(Context.t() | map() | keyword()) :: {:ok, Resolution.t()} | {:error, term()}
  def resolve(context \\ %{}) do
    context = Context.host(context)

    case Resolver.resolve(claims(), key(), context, contract: V1.ref()) do
      {:ok, resolution} -> {:ok, resolution}
      {:error, %{status: {:error, reason}}} -> {:error, {:workbench_resolution, reason}}
    end
  end

  @doc "Release a mounted workbench's managed-generation lease."
  @spec release(Handle.t()) :: :ok
  def release(%Handle{} = handle), do: Handle.release(handle)

  @doc "Invoke and validate the pinned workbench mount callback."
  @spec mount(Handle.t(), map()) :: V1.transition()
  def mount(%Handle{} = handle, context), do: invoke_transition(handle, :mount, [context])

  @doc "Invoke and validate one pinned workbench event callback."
  @spec event(Handle.t(), String.t(), map(), map(), map()) :: V1.transition()
  def event(%Handle{} = handle, event, params, state, context),
    do: invoke_transition(handle, :event, [event, params, state, context])

  @doc "Invoke and validate one pinned workbench info callback."
  @spec info(Handle.t(), term(), map(), map()) :: V1.transition()
  def info(%Handle{} = handle, message, state, context),
    do: invoke_transition(handle, :info, [message, state, context])

  @doc "Resolve and validate the render target reference for current state."
  @spec render_target(Handle.t(), map()) :: {:ok, V1.render_target()} | {:error, term()}
  def render_target(%Handle{} = handle, state) do
    with {:ok, result} <- invoke_callback(handle, :render_target, [state]) do
      case result do
        target when is_binary(target) and byte_size(target) > 0 -> {:ok, target}
        {module, function} = target when is_atom(module) and is_atom(function) -> {:ok, target}
        invalid -> {:error, {:invalid_workbench_render_target, invalid}}
      end
    end
  end

  @doc "Resolve and validate raw form values owned by the stable host."
  @spec forms(Handle.t(), map()) :: {:ok, %{optional(atom()) => map()}} | {:error, term()}
  def forms(%Handle{} = handle, state) do
    with {:ok, result} <- invoke_callback(handle, :forms, [state]) do
      case result do
        forms when is_map(forms) -> validate_forms(forms)
        invalid -> {:error, {:invalid_workbench_forms, invalid}}
      end
    end
  end

  @doc "Create and validate a bounded handoff capsule through the pinned workbench."
  @spec snapshot(Handle.t(), map()) :: {:ok, V1.capsule()} | {:error, term()}
  def snapshot(%Handle{} = handle, state) do
    with :ok <- ensure_callback(handle, :snapshot, 1),
         {:ok, result} <- invoke_callback(handle, :snapshot, [state]),
         {:ok, capsule} <- normalize_snapshot(result) do
      V1.validate_capsule(capsule)
    end
  end

  @doc "Restore a capsule through a newly pinned workbench target."
  @spec restore(Handle.t(), V1.capsule(), map()) :: V1.transition()
  def restore(%Handle{} = handle, capsule, context) do
    with {:ok, capsule} <- V1.validate_capsule(capsule),
         :ok <- ensure_callback(handle, :restore, 2) do
      invoke_transition(handle, :restore, [capsule, context])
    end
  end

  @doc "Export managed and built-in workbench claims."
  @spec claims() :: [Claim.t()]
  def claims, do: managed_claims() ++ [builtin_claim()]

  @doc false
  @spec unmanaged_claims() :: [Claim.t()]
  def unmanaged_claims, do: [builtin_claim()]

  @doc "Return the default workbench service key."
  @spec key() :: ServiceKey.t()
  def key, do: ServiceKey.new!("ui", "workbench", "default")

  @doc "Project a workbench resolution into serializable mount diagnostics."
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
      implementation: inspect(ImplementationRef.logical(claim.implementation)),
      generation: Map.get(claim.metadata, :runtime_generation)
    }
  end

  defp invoke_transition(handle, callback, args) do
    with {:ok, result} <- invoke_callback(handle, callback, args) do
      V1.validate_transition(result)
    end
  end

  defp invoke_callback(handle, callback, args) do
    task = Tasks.async(fn -> invoke(handle, callback, args) end)

    case Tasks.await(task, callback_timeout()) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, {:workbench_callback_failed, callback, reason}}
      :timeout -> {:error, {:workbench_callback_timeout, callback}}
    end
  end

  defp ensure_callback(
         %Handle{
           resolution: %Resolution{
             claim: %Claim{implementation: %ImplementationRef{transport: :process}}
           }
         },
         _callback,
         _arity
       ),
       do: :ok

  defp ensure_callback(
         %Handle{
           resolution: %Resolution{
             claim: %Claim{
               implementation: %ImplementationRef{transport: :local, target: module}
             }
           }
         },
         callback,
         arity
       ),
       do: ensure_local_callback(module, callback, arity)

  defp ensure_callback(%Handle{implementation: module}, callback, arity) when is_atom(module) do
    ensure_local_callback(module, callback, arity)
  end

  defp ensure_callback(_handle, callback, _arity),
    do: {:error, {:workbench_handoff_not_supported, callback}}

  defp ensure_local_callback(module, callback, arity) do
    case is_atom(module) and Code.ensure_loaded?(module) and
           function_exported?(module, callback, arity) do
      true -> :ok
      false -> {:error, {:workbench_handoff_not_supported, callback}}
    end
  end

  defp normalize_snapshot({:ok, capsule}), do: {:ok, capsule}
  defp normalize_snapshot({:error, _reason} = error), do: error
  defp normalize_snapshot(invalid), do: {:error, {:invalid_workbench_snapshot_result, invalid}}

  defp invoke(%Handle{} = handle, callback, args) do
    Transport.invoke(handle, callback, args)
  end

  defp validate_forms(forms) do
    invalid =
      Enum.find(forms, fn
        {name, values} when is_atom(name) and is_map(values) ->
          Enum.any?(Map.keys(values), &(not is_binary(&1)))

        _invalid ->
          true
      end)

    case invalid do
      nil -> validate_forms_size(forms)
      invalid -> {:error, {:invalid_workbench_form, invalid}}
    end
  end

  defp validate_forms_size(forms) do
    case Jason.encode(forms) do
      {:ok, json} when byte_size(json) <= @max_forms_bytes -> {:ok, forms}
      {:ok, json} -> {:error, {:workbench_forms_too_large, byte_size(json), @max_forms_bytes}}
      {:error, reason} -> {:error, {:invalid_workbench_forms, reason}}
    end
  end

  defp callback_timeout do
    Application.get_env(:catalyst_web, :workbench_callback_timeout, @default_callback_timeout)
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
      implementation: CatalystWeb.Workbench.IDE,
      owner: :builtin,
      scope: Scope.global(),
      priority: 0,
      binding: {:pin, :mount},
      provenance: :builtin,
      metadata: %{}
    }
  end
end
