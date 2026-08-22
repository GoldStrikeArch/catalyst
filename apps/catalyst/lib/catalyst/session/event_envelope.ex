defmodule Catalyst.Session.EventEnvelope do
  @moduledoc """
  Versioned input delivered to a session engine and, for durable payloads, the
  transcript store.

  PubSub continues receiving the enclosed raw event. `causation_id` and
  `producer_contract` stay nil when the host does not possess that information;
  the envelope never infers identity from message contents.
  """

  alias Catalyst.Runtime.ContractRef

  @enforce_keys [:event_id, :session_id, :event, :payload_schema_version]
  defstruct @enforce_keys ++
              [
                version: 1,
                causation_id: nil,
                correlation_id: nil,
                producer_contract: nil
              ]

  @type t :: %__MODULE__{
          version: 1,
          event_id: String.t(),
          session_id: String.t(),
          causation_id: String.t() | nil,
          correlation_id: String.t() | nil,
          producer_contract: ContractRef.t() | nil,
          payload_schema_version: pos_integer(),
          event: term()
        }

  @doc "Wrap one accepted agent event for the session engine."
  @spec new(term(), String.t(), keyword() | String.t() | nil) :: t()
  def new(event, session_id, opts \\ []) when is_binary(session_id) do
    opts = normalize_opts(opts)

    %__MODULE__{
      event: event,
      event_id: Keyword.get_lazy(opts, :event_id, fn -> Catalyst.Ids.hex(16) end),
      session_id: session_id,
      causation_id: Keyword.get(opts, :causation_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      producer_contract: normalize_contract(Keyword.get(opts, :producer_contract)),
      payload_schema_version: Keyword.get(opts, :payload_schema_version, 1)
    }
  end

  defp normalize_opts(nil), do: []
  defp normalize_opts(run_id) when is_binary(run_id), do: [correlation_id: run_id]
  defp normalize_opts(opts) when is_list(opts), do: opts

  defp normalize_contract(nil), do: nil
  defp normalize_contract(%ContractRef{} = contract), do: contract

  defp normalize_contract(%{id: id, version: version}),
    do: ContractRef.new!(id, version)
end
