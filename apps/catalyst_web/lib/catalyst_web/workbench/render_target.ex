defmodule CatalystWeb.Workbench.RenderTarget do
  @moduledoc """
  Immutable render descriptor captured at a Workbench mount boundary.

  Legacy string IDs are captured from the UI registry once. A built-in or
  artifact-backed managed Workbench may instead render through its own exact
  implementation module. A mounted Workbench never resolves either target again.
  """

  alias Catalyst.Runtime.{ActivationId, ArtifactId, Claim, Handle, ImplementationRef, Resolution}
  alias CatalystWeb.UI.Registry

  @enforce_keys [
    :id,
    :module,
    :function,
    :owner,
    :sequence,
    :snapshot_id,
    :generation,
    :artifact
  ]
  defstruct @enforce_keys

  @type target_ref :: Catalyst.Contracts.Workbench.V1.render_target()
  @type t :: %__MODULE__{
          id: target_ref(),
          module: module(),
          function: atom(),
          owner: term(),
          sequence: non_neg_integer() | nil,
          snapshot_id: String.t(),
          generation: String.t() | nil,
          artifact: ArtifactId.t() | nil
        }

  @doc "Capture and validate one target against the pinned Workbench handle."
  @spec capture(target_ref(), Handle.t()) :: {:ok, t()} | {:error, term()}
  def capture(id, %Handle{resolution: %Resolution{} = resolution}) when is_binary(id) do
    Registry.list_pages()
    |> Enum.find(&(&1.path == id))
    |> build(id, resolution)
  end

  def capture({module, function} = target, %Handle{} = handle)
      when is_atom(module) and is_atom(function),
      do: build_direct(target, handle)

  def capture(target, _handle), do: {:error, {:invalid_workbench_render_target, target}}

  @doc "Require a later Workbench state to retain its mount-pinned target ID."
  @spec validate_id(t(), target_ref()) :: :ok | {:error, term()}
  def validate_id(%__MODULE__{id: id}, id), do: :ok

  def validate_id(%__MODULE__{id: pinned}, current),
    do: {:error, {:workbench_render_target_changed, pinned, current}}

  defp build(nil, _id, _resolution), do: {:error, :workbench_render_target_not_registered}

  defp build(entry, id, resolution) do
    with :ok <- validate_entry(entry, id) do
      {:ok,
       %__MODULE__{
         id: id,
         module: entry.mod,
         function: entry.fun,
         owner: entry.owner,
         sequence: entry.seq,
         snapshot_id: resolution.snapshot_id,
         generation: Map.get(resolution.claim.metadata, :runtime_generation),
         artifact: nil
       }}
    end
  end

  defp build_direct(
         {module, function} = target,
         %Handle{
           implementation: module,
           generation: nil,
           artifact: nil,
           resolution: %Resolution{
             claim: %Claim{owner: :builtin, implementation: module}
           }
         } = handle
       ) do
    with :ok <- validate_callback(module, function, target) do
      {:ok,
       %__MODULE__{
         id: target,
         module: module,
         function: function,
         owner: :builtin,
         sequence: nil,
         snapshot_id: handle.resolution.snapshot_id,
         generation: nil,
         artifact: nil
       }}
    end
  end

  defp build_direct(
         {module, function} = target,
         %Handle{
           implementation: module,
           generation: %ActivationId{},
           artifact: %ArtifactId{} = artifact,
           resolution: %Resolution{
             claim: %Claim{
               implementation: %ImplementationRef{
                 transport: :local,
                 target: module,
                 artifact: artifact
               }
             }
           }
         } = handle
       ) do
    with :ok <- validate_callback(module, function, target) do
      {:ok,
       %__MODULE__{
         id: target,
         module: module,
         function: function,
         owner: handle.owner,
         sequence: nil,
         snapshot_id: handle.resolution.snapshot_id,
         generation: ActivationId.to_wire(handle.generation),
         artifact: artifact
       }}
    end
  end

  defp build_direct(target, _handle),
    do: {:error, {:workbench_render_target_not_pinned, target}}

  defp validate_entry(%{mod: module, fun: function, seq: sequence}, id)
       when is_atom(module) and is_atom(function) and is_integer(sequence) and sequence >= 0 do
    validate_callback(module, function, id)
  end

  defp validate_entry(entry, id),
    do: {:error, {:invalid_workbench_render_target_descriptor, id, entry}}

  defp validate_callback(module, function, id) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> validate_export(module, function, id)
      {:error, reason} -> {:error, {:workbench_render_target_unavailable, id, reason}}
    end
  end

  defp validate_export(module, function, id) do
    case function_exported?(module, function, 1) do
      true -> :ok
      false -> {:error, {:workbench_render_target_unavailable, id, :undefined}}
    end
  end
end
