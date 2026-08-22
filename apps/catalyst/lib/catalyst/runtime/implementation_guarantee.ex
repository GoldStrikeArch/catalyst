defmodule Catalyst.Runtime.ImplementationGuarantee do
  @moduledoc """
  Describes the observable execution guarantee of a runtime implementation.

  Classification comes from the concrete `ImplementationRef` and active
  manifest declarations, never from an extension's trust label. In particular,
  `:external_worker` means a separate worker process provides crash isolation;
  it does not imply an operating-system filesystem or network sandbox.

  `:raw_legacy_opaque` is an owner-level classification for extensions whose
  imperative or raw side effects are not fully represented by managed claims.
  """

  alias Catalyst.Extension.Manifest
  alias Catalyst.Runtime.{ArtifactId, ImplementationRef}

  @type t ::
          :artifact_qualified_local
          | :external_worker
          | :sovereign_local_process
          | :same_name_local
          | :raw_legacy_opaque

  @doc "Classify one claim's concrete implementation target."
  @spec classify(ImplementationRef.t() | term()) :: t()
  def classify(%ImplementationRef{transport: :local, artifact: %ArtifactId{}}),
    do: :artifact_qualified_local

  def classify(%ImplementationRef{transport: :external_worker}), do: :external_worker
  def classify(%ImplementationRef{transport: :process}), do: :sovereign_local_process
  def classify(%ImplementationRef{transport: :local}), do: :same_name_local
  def classify(_same_name_local), do: :same_name_local

  @doc "List the distinct implementation guarantees declared by managed manifests."
  @spec manifests([Manifest.t()]) :: [t()]
  def manifests(manifests) when is_list(manifests) do
    manifests
    |> Enum.flat_map(& &1.services)
    |> Enum.map(&service_implementation/1)
    |> Enum.map(&classify/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Classify an extension owner using the active managed-owner composition."
  @spec owner(String.t(), %{optional(String.t()) => [Manifest.t()]}) :: [t()]
  def owner(owner, managed_owners) when is_binary(owner) and is_map(managed_owners) do
    case Map.fetch(managed_owners, owner) do
      {:ok, manifests} -> manifests(manifests)
      :error -> [:raw_legacy_opaque]
    end
  end

  @doc "Short UI label for a guarantee classification."
  @spec label(t()) :: String.t()
  def label(:artifact_qualified_local), do: "artifact-qualified local"
  def label(:external_worker), do: "external worker"
  def label(:sovereign_local_process), do: "sovereign local process"
  def label(:same_name_local), do: "same-name local"
  def label(:raw_legacy_opaque), do: "raw / legacy opaque"

  @doc "Honest boundary description for a guarantee classification."
  @spec description(t()) :: String.t()
  def description(:artifact_qualified_local),
    do:
      "Exact artifact identity; retained code still depends on generation leases and purge lifecycle."

  def description(:external_worker),
    do: "Separate worker process for crash isolation; not an OS filesystem or network sandbox."

  def description(:sovereign_local_process),
    do: "Invoked through a local process protocol; it remains inside the host BEAM node."

  def description(:same_name_local),
    do: "Local same-name code without an artifact identity; reload or purge may replace it."

  def description(:raw_legacy_opaque),
    do: "Imperative or raw extension; the runtime cannot fully observe its side effects."

  defp service_implementation(service) when is_map(service),
    do: Map.fetch!(service, :implementation)

  defp service_implementation(service) when is_list(service),
    do: Keyword.fetch!(service, :implementation)
end
