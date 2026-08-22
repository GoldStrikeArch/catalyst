defmodule Catalyst.Session.EventEnvelope do
  @moduledoc """
  Versioned, process-local input delivered to a session engine.

  Version one deliberately leaves persistence and PubSub wire shapes unchanged;
  external observers continue receiving the enclosed `Catalyst.Agent.Event`.
  """

  alias Catalyst.Agent.Event

  @enforce_keys [:session_id, :event]
  defstruct @enforce_keys ++ [version: 1, run_id: nil]

  @type t :: %__MODULE__{
          version: 1,
          session_id: String.t(),
          run_id: String.t() | nil,
          event: Event.t()
        }

  @doc "Wrap one accepted agent event for the session engine."
  @spec new(Event.t(), String.t(), String.t() | nil) :: t()
  def new(event, session_id, run_id \\ nil)
      when is_binary(session_id) and (is_binary(run_id) or is_nil(run_id)) do
    %__MODULE__{event: event, session_id: session_id, run_id: run_id}
  end
end
