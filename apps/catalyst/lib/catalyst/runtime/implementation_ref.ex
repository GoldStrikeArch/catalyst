defmodule Catalyst.Runtime.ImplementationRef do
  @moduledoc """
  Separates a service implementation's logical identity from its execution target.

  The logical value participates in graph identity and diagnostics. The target is
  the exact local module, named OTP process, or candidate-owned external worker
  invoked by a pinned handle.
  """

  alias Catalyst.Runtime.ArtifactId

  @enforce_keys [:logical, :target, :transport]
  defstruct @enforce_keys ++ [artifact: nil]

  @type process_target :: %{server: GenServer.server(), protocol: term()}
  @type external_worker_target :: %{protocol: term()}
  @type transport :: :local | :process | :external_worker
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

  @doc "Build a reference to a sovereign OTP process implementing a service protocol."
  @spec process(term(), GenServer.server(), term()) :: t()
  def process(logical, server, protocol) do
    %__MODULE__{
      logical: logical,
      target: %{server: server, protocol: protocol},
      transport: :process
    }
  end

  @doc "Build a reference to an external worker owned by the claim's generation."
  @spec external_worker(term(), term()) :: t()
  def external_worker(logical, protocol) do
    %__MODULE__{
      logical: logical,
      target: %{protocol: protocol},
      transport: :external_worker
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

  @doc "Return the transport used to invoke an implementation."
  @spec transport(t() | term()) :: transport()
  def transport(%__MODULE__{transport: transport}), do: transport
  def transport(_implementation), do: :local

  @doc "Return a digest-safe representation that excludes physical target identity."
  @spec digest_term(t() | term()) :: term()
  def digest_term(%__MODULE__{} = reference) do
    %{
      logical: reference.logical,
      transport: reference.transport,
      protocol: protocol(reference)
    }
  end

  def digest_term(implementation), do: implementation

  defp protocol(%__MODULE__{transport: :process, target: %{protocol: protocol}}), do: protocol

  defp protocol(%__MODULE__{transport: :external_worker, target: %{protocol: protocol}}),
    do: protocol

  defp protocol(%__MODULE__{}), do: nil
end
