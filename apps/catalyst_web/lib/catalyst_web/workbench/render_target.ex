defmodule CatalystWeb.Workbench.RenderTarget do
  @moduledoc """
  Immutable render descriptor captured at a Workbench mount boundary.

  The legacy UI registry remains the compatibility source for target IDs, but
  a mounted Workbench never consults it again. Registry replacement therefore
  affects only a new mount or an explicit Workbench remount.
  """

  alias Catalyst.Runtime.Resolution
  alias CatalystWeb.UI.Registry

  @enforce_keys [
    :id,
    :module,
    :function,
    :owner,
    :sequence,
    :snapshot_id,
    :generation
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          module: module(),
          function: atom(),
          owner: term(),
          sequence: non_neg_integer(),
          snapshot_id: String.t(),
          generation: String.t() | nil
        }

  @doc "Capture and validate the effective registry target for one pinned resolution."
  @spec capture(String.t(), Resolution.t()) :: {:ok, t()} | {:error, term()}
  def capture(id, %Resolution{} = resolution) when is_binary(id) do
    Registry.list_pages()
    |> Enum.find(&(&1.path == id))
    |> build(id, resolution)
  end

  def capture(id, _resolution), do: {:error, {:invalid_workbench_render_target, id}}

  @doc "Require a later Workbench state to retain its mount-pinned target ID."
  @spec validate_id(t(), String.t()) :: :ok | {:error, term()}
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
         generation: Map.get(resolution.claim.metadata, :runtime_generation)
       }}
    end
  end

  defp validate_entry(%{mod: module, fun: function, seq: sequence}, id)
       when is_atom(module) and is_atom(function) and is_integer(sequence) and sequence >= 0 do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> validate_callback(module, function, id)
      {:error, reason} -> {:error, {:workbench_render_target_unavailable, id, reason}}
    end
  end

  defp validate_entry(entry, id),
    do: {:error, {:invalid_workbench_render_target_descriptor, id, entry}}

  defp validate_callback(module, function, id) do
    case function_exported?(module, function, 1) do
      true -> :ok
      false -> {:error, {:workbench_render_target_unavailable, id, :undefined}}
    end
  end
end
