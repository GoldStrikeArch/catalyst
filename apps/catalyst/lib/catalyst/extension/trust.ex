defmodule Catalyst.Extension.Trust do
  @moduledoc """
  Trust classes declared by extension manifests.

  `:compiled_trusted` and `:local_trusted` execute in the Catalyst VM and are
  therefore unrestricted. `:isolated_worker` and `:remote_service` describe
  implementations that must be reached through an external transport before
  their resource policy can be enforced as an isolation boundary.
  """

  @classes [:compiled_trusted, :local_trusted, :isolated_worker, :remote_service]

  @type t :: :compiled_trusted | :local_trusted | :isolated_worker | :remote_service

  @doc "Return every supported manifest trust class."
  @spec classes() :: [t()]
  def classes, do: @classes

  @doc "Return whether a trust class executes without VM isolation."
  @spec unrestricted?(t()) :: boolean()
  def unrestricted?(trust), do: trust in [:compiled_trusted, :local_trusted]

  @doc "Return whether a trust class requires an external transport boundary."
  @spec isolated?(t()) :: boolean()
  def isolated?(trust), do: trust in [:isolated_worker, :remote_service]

  @doc "Validate a trust class at a manifest boundary."
  @spec validate(term()) :: :ok | {:error, {:invalid_manifest_trust, term()}}
  def validate(trust) when trust in @classes, do: :ok
  def validate(trust), do: {:error, {:invalid_manifest_trust, trust}}
end
