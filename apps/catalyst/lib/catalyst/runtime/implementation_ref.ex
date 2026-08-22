defmodule Catalyst.Runtime.ImplementationRef do
  @moduledoc """
  Separates a service implementation's logical identity from its execution target.

  The logical value participates in graph identity and diagnostics. The target is
  the exact local module or remote endpoint invoked by a pinned handle.
  """

  alias Catalyst.Runtime.ArtifactId

  @enforce_keys [:logical, :target, :transport]
  defstruct @enforce_keys ++ [artifact: nil]

  @type transport :: :local
  @type t :: %__MODULE__{
          logical: term(),
          target: term(),
          transport: transport(),
          artifact: ArtifactId.t() | nil
        }

  @doc "Build a local implementation reference."
  @spec local(term(), term(), ArtifactId.t() | nil) :: t()
  def local(logical, target, artifact \\ nil) do
    %__MODULE__{
      logical: logical,
      target: target,
      transport: :local,
      artifact: artifact
    }
  end

  @doc "Return the implementation's stable logical identity."
  @spec logical(t() | term()) :: term()
  def logical(%__MODULE__{logical: logical}), do: logical
  def logical(implementation), do: implementation

  @doc "Return the concrete target invoked by the current runtime."
  @spec target(t() | term()) :: term()
  def target(%__MODULE__{target: target}), do: target
  def target(implementation), do: implementation

  @doc "Return a digest-safe representation that excludes physical target identity."
  @spec digest_term(t() | term()) :: term()
  def digest_term(%__MODULE__{} = reference) do
    %{logical: reference.logical, transport: reference.transport}
  end

  def digest_term(implementation), do: implementation
end
