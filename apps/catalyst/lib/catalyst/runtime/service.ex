defmodule Catalyst.Runtime.Service do
  @moduledoc """
  Shared acquisition boundary for resolved runtime services.

  Unmanaged built-ins produce a handle without contacting the generation
  coordinator. Managed services normalize coordinator restarts into tagged
  errors so callers outside the runtime supervision group can fail closed or
  retry without exiting.
  """

  alias Catalyst.Runtime.{Generations, Handle, Resolution}

  @doc "Acquire a process-owned handle for a resolved runtime service."
  @spec acquire(Resolution.t(), pid()) :: {:ok, Handle.t()} | {:error, term()}
  def acquire(%Resolution{} = resolution, owner \\ self()) when is_pid(owner) do
    case Map.get(resolution.claim.metadata, :runtime_generation) do
      nil -> {:ok, Handle.new(resolution, nil)}
      _generation -> acquire_managed(resolution, owner)
    end
  end

  defp acquire_managed(resolution, owner) do
    with {:ok, lease} <- Generations.acquire_lease(resolution, owner) do
      {:ok, Handle.new(resolution, lease)}
    end
  catch
    :exit, reason -> {:error, {:runtime_generation_unavailable, reason}}
  end
end
