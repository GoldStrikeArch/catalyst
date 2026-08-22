defmodule Catalyst.Contracts.TranscriptStore.V1 do
  @moduledoc """
  Version-one contract for a session transcript store.

  Backends own their private handles and persistence format. The runtime host
  requires a stable local identity for existing diagnostics and delegates every
  session read/write through the pinned implementation.
  """

  alias Catalyst.Agent.Event
  alias Catalyst.Message
  alias Catalyst.Runtime.ContractRef
  alias Catalyst.Session.Store

  @typedoc "Backend-private open transcript handle."
  @type handle :: term()

  @typedoc "Identity required by the current session catalog and diagnostics."
  @type identity :: %{id: String.t(), path: String.t(), cwd: String.t()}

  @callback open(String.t(), keyword()) :: {:ok, handle()} | {:error, term()}
  @callback create_new(String.t(), keyword()) :: {:ok, handle()} | {:error, term()}
  @callback describe(handle()) :: {:ok, identity()} | {:error, term()}
  @callback load_state(handle()) :: {:ok, Store.loaded_state()} | {:error, term()}
  @callback append_message(handle(), Message.t()) :: :ok | {:error, term()}
  @callback append_reset(handle()) :: :ok | {:error, term()}
  @callback append_compaction(handle(), Event.ContextCompacted.t()) :: :ok | {:error, term()}
  @callback append_settings_snapshot(handle(), Store.persisted_settings()) ::
              :ok | {:error, term()}
  @callback close(handle()) :: :ok

  @doc "Return the stable Runtime Graph contract reference."
  @spec ref() :: ContractRef.t()
  def ref, do: ContractRef.new!("catalyst.transcript-store", 1)
end
