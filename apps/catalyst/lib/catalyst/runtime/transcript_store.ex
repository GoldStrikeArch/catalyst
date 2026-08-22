defmodule Catalyst.Runtime.TranscriptStore do
  @moduledoc """
  Runtime Graph adapter for the session-pinned transcript store.

  The adapter retains the existing JSONL backend and public `Session.Store` API
  while routing `Session.Server` persistence through a versioned logical handle.
  Replacements apply to new sessions only.
  """

  alias Catalyst.Contracts.TranscriptStore.V1

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

  alias Catalyst.Session.TranscriptStore.Handle, as: StoreHandle

  @doc "Open or resume a transcript through the effective pinned backend."
  @spec open(String.t(), keyword(), Context.t() | map() | keyword()) ::
          {:ok, StoreHandle.t()} | {:error, term()}
  def open(cwd, opts, context \\ %{}), do: open_with(:open, cwd, opts, context)

  @doc "Exclusively create a transcript through the effective pinned backend."
  @spec create_new(String.t(), keyword(), Context.t() | map() | keyword()) ::
          {:ok, StoreHandle.t()} | {:error, term()}
  def create_new(cwd, opts, context \\ %{}), do: open_with(:create_new, cwd, opts, context)

  @doc "Load transcript and settings through the pinned backend."
  @spec load_state(StoreHandle.t()) ::
          {:ok, Catalyst.Session.Store.loaded_state()} | {:error, term()}
  def load_state(%StoreHandle{} = handle), do: invoke(handle, :load_state, [])

  @doc "Append a versioned durable event through the pinned backend."
  @spec append(StoreHandle.t(), Catalyst.Session.EventEnvelope.t()) :: :ok | {:error, term()}
  def append(%StoreHandle{} = handle, %Catalyst.Session.EventEnvelope{} = envelope),
    do: invoke(handle, :append, [envelope])

  @doc "Close the backend handle and release its managed-generation lease."
  @spec close(StoreHandle.t()) :: :ok
  def close(%StoreHandle{} = handle) do
    try do
      :ok = invoke(handle, :close, [])
    after
      :ok = Handle.release(handle.runtime_handle)
    end
  end

  @doc "Resolve the effective default transcript store."
  @spec resolve(Context.t() | map() | keyword()) :: {:ok, Resolution.t()} | {:error, term()}
  def resolve(context \\ %{}) do
    context = Context.new(context)

    case Resolver.resolve(claims(), key(), context, contract: V1.ref()) do
      {:ok, resolution} -> {:ok, resolution}
      {:error, %{status: {:error, reason}}} -> {:error, {:transcript_store_resolution, reason}}
    end
  end

  @doc "Explain the effective transcript store without opening a session."
  @spec explain(Context.t() | map() | keyword()) :: Catalyst.Runtime.Explanation.t()
  def explain(context \\ %{}) do
    Resolver.explain(claims(), key(), Context.new(context), contract: V1.ref())
  end

  @doc "Export the managed and built-in transcript-store claims."
  @spec claims() :: [Claim.t()]
  def claims, do: managed_claims() ++ [builtin_claim()]

  @doc false
  @spec unmanaged_claims() :: [Claim.t()]
  def unmanaged_claims, do: [builtin_claim()]

  @doc "Return the default transcript-store service key."
  @spec key() :: ServiceKey.t()
  def key, do: ServiceKey.new!("agent", "transcript_store", "default")

  @doc "Project a transcript-store resolution into serializable diagnostics."
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
      implementation: ImplementationRef.logical(claim.implementation),
      handle_version: 1
    }

    case Map.get(claim.metadata, :runtime_generation) do
      nil -> metadata
      generation -> Map.put(metadata, :generation, generation)
    end
  end

  defp open_with(operation, cwd, opts, context) do
    with {:ok, runtime_handle} <- resolve_and_pin(context, self()),
         result <- invoke(runtime_handle, operation, [cwd, opts]) do
      finish_open(result, runtime_handle)
    end
  end

  defp finish_open({:ok, backend_handle}, runtime_handle) do
    case invoke(runtime_handle, :describe, [backend_handle]) do
      {:ok, %{id: id, path: path, cwd: cwd}}
      when is_binary(id) and is_binary(path) and is_binary(cwd) ->
        {:ok,
         %StoreHandle{
           runtime_handle: runtime_handle,
           backend_handle: backend_handle,
           id: id,
           path: path,
           cwd: cwd,
           metadata: metadata(runtime_handle.resolution)
         }}

      {:error, _reason} = error ->
        release_failed_open(runtime_handle, backend_handle, error)

      invalid ->
        release_failed_open(
          runtime_handle,
          backend_handle,
          {:error, {:invalid_transcript_store_identity, invalid}}
        )
    end
  end

  defp finish_open({:error, _reason} = error, runtime_handle) do
    :ok = Handle.release(runtime_handle)
    error
  end

  defp finish_open(invalid, runtime_handle) do
    :ok = Handle.release(runtime_handle)
    {:error, {:invalid_transcript_store_open_result, invalid}}
  end

  defp release_failed_open(runtime_handle, backend_handle, error) do
    _result = invoke(runtime_handle, :close, [backend_handle])
    :ok = Handle.release(runtime_handle)
    error
  end

  defp resolve_and_pin(context, owner, retries \\ 1) do
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

  defp invoke(%StoreHandle{} = handle, function, args) do
    invoke(handle.runtime_handle, function, [handle.backend_handle | args])
  end

  defp invoke(%Handle{} = handle, function, args) do
    case ImplementationRef.transport(handle.resolution.claim.implementation) do
      :local -> apply(handle.implementation, function, args)
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
      implementation: Catalyst.Session.JSONLTranscriptStore,
      owner: :builtin,
      scope: Scope.global(),
      priority: 0,
      binding: {:pin, :session},
      provenance: :builtin,
      metadata: %{}
    }
  end
end
