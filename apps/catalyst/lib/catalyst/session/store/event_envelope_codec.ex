defmodule Catalyst.Session.Store.EventEnvelopeCodec do
  @moduledoc """
  JSON-safe codec for durable version-one session event envelopes.

  The payload intentionally reuses legacy JSONL entry shapes. That makes replay
  of legacy records and enveloped records converge through the same fold.
  """

  alias Catalyst.Agent.Event
  alias Catalyst.Context.Transcript
  alias Catalyst.Runtime.ContractRef
  alias Catalyst.Session.EventEnvelope
  alias Catalyst.Session.Store.Codec

  @doc "Encode a durable envelope into one JSONL entry map."
  @spec encode(EventEnvelope.t()) :: {:ok, map()} | {:error, term()}
  def encode(%EventEnvelope{} = envelope) do
    with :ok <- validate_envelope(envelope),
         {:ok, payload} <- encode_payload(envelope.event) do
      {:ok,
       %{
         "type" => "event",
         "envelope" =>
           %{
             "version" => 1,
             "eventId" => envelope.event_id,
             "sessionId" => envelope.session_id,
             "payloadSchemaVersion" => envelope.payload_schema_version,
             "payload" => payload
           }
           |> maybe_put("causationId", envelope.causation_id)
           |> maybe_put("correlationId", envelope.correlation_id)
           |> maybe_put("producerContract", encode_contract(envelope.producer_contract))
       }}
    end
  end

  def encode(envelope), do: {:error, {:invalid_event_envelope, envelope}}

  @doc "Decode and validate one JSONL envelope entry."
  @spec decode(term()) :: {:ok, EventEnvelope.t()} | {:error, term()}
  def decode(%{"type" => "event", "envelope" => envelope}) when is_map(envelope) do
    with :ok <- validate_version(envelope["version"]),
         {:ok, event_id} <- required_binary(envelope, "eventId"),
         {:ok, session_id} <- required_binary(envelope, "sessionId"),
         :ok <- validate_payload_version(envelope["payloadSchemaVersion"]),
         {:ok, causation_id} <- optional_binary(envelope, "causationId"),
         {:ok, correlation_id} <- optional_binary(envelope, "correlationId"),
         {:ok, producer_contract} <- decode_contract(envelope["producerContract"]),
         {:ok, payload} <- decode_payload(envelope["payload"]) do
      {:ok,
       %EventEnvelope{
         version: 1,
         event_id: event_id,
         session_id: session_id,
         causation_id: causation_id,
         correlation_id: correlation_id,
         producer_contract: producer_contract,
         payload_schema_version: 1,
         event: payload
       }}
    end
  end

  def decode(entry), do: {:error, {:invalid_event_envelope, entry}}

  defp validate_envelope(%EventEnvelope{
         version: 1,
         event_id: event_id,
         session_id: session_id,
         causation_id: causation_id,
         correlation_id: correlation_id,
         producer_contract: producer,
         payload_schema_version: 1
       }) do
    with :ok <- validate_nonempty_binary(:event_id, event_id),
         :ok <- validate_nonempty_binary(:session_id, session_id),
         :ok <- validate_optional_binary(:causation_id, causation_id),
         :ok <- validate_optional_binary(:correlation_id, correlation_id),
         :ok <- validate_producer(producer) do
      :ok
    end
  end

  defp validate_envelope(%EventEnvelope{version: version}) when version != 1,
    do: {:error, {:unsupported_event_envelope_version, version}}

  defp validate_envelope(%EventEnvelope{payload_schema_version: version}),
    do: {:error, {:unsupported_event_payload_schema, version}}

  defp validate_version(1), do: :ok

  defp validate_version(version),
    do: {:error, {:unsupported_event_envelope_version, version}}

  defp validate_payload_version(1), do: :ok

  defp validate_payload_version(version),
    do: {:error, {:unsupported_event_payload_schema, version}}

  defp validate_nonempty_binary(_field, value) when is_binary(value) and byte_size(value) > 0,
    do: :ok

  defp validate_nonempty_binary(field, value),
    do: {:error, {:invalid_event_envelope_field, field, value}}

  defp validate_optional_binary(_field, nil), do: :ok
  defp validate_optional_binary(field, value), do: validate_nonempty_binary(field, value)

  defp validate_producer(nil), do: :ok

  defp validate_producer(%ContractRef{id: id, version: version} = contract) do
    case ContractRef.new(id, version) do
      {:ok, ^contract} -> :ok
      {:error, _reason} -> {:error, {:invalid_event_producer_contract, contract}}
    end
  end

  defp validate_producer(value), do: {:error, {:invalid_event_producer_contract, value}}

  defp required_binary(map, key) do
    case map[key] do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      value -> {:error, {:invalid_event_envelope_field, key, value}}
    end
  end

  defp optional_binary(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      value -> {:error, {:invalid_event_envelope_field, key, value}}
    end
  end

  defp encode_contract(nil), do: nil

  defp encode_contract(%ContractRef{id: id, version: version}),
    do: %{"id" => id, "version" => version}

  defp decode_contract(nil), do: {:ok, nil}

  defp decode_contract(%{"id" => id, "version" => version}) do
    case ContractRef.new(id, version) do
      {:ok, contract} ->
        {:ok, contract}

      {:error, _reason} ->
        {:error, {:invalid_event_producer_contract, %{"id" => id, "version" => version}}}
    end
  end

  defp decode_contract(value), do: {:error, {:invalid_event_producer_contract, value}}

  defp encode_payload(%Event.MessageEnd{message: message}) do
    {:ok, %{"type" => "message", "message" => Codec.encode(message)}}
  end

  defp encode_payload(%Event.ContextCompacted{} = compaction) do
    {:ok,
     %{
       "type" => "compaction",
       "replacement" => Enum.map(compaction.replacement, &Codec.encode/1),
       "summary" => encode_optional_message(compaction.summary),
       "replacedCount" => compaction.replaced_count,
       "tokensBefore" => compaction.tokens_before,
       "tokensAfter" => compaction.tokens_after,
       "policy" => inspect(compaction.policy)
     }}
  end

  defp encode_payload(:reset), do: {:ok, %{"type" => "reset"}}

  defp encode_payload({:settings_snapshot, settings}) when is_map(settings) do
    case valid_settings?(settings) do
      true ->
        {:ok,
         %{
           "type" => "settings_snapshot",
           "model" => encode_model(settings.model),
           "thinking_level" => settings.thinking_level,
           "workflow" => settings.workflow,
           "system_prompt" => settings.system_prompt
         }}

      false ->
        {:error, {:invalid_event_payload, {:settings_snapshot, settings}}}
    end
  end

  defp encode_payload(payload), do: {:error, {:unsupported_durable_event_payload, payload}}

  defp decode_payload(%{"type" => "message", "message" => message} = payload) do
    case Codec.decode(message) do
      {:ok, _decoded} -> {:ok, payload}
      {:error, reason} -> invalid_payload(reason)
    end
  end

  defp decode_payload(%{"type" => "compaction", "replacement" => replacement} = payload)
       when is_list(replacement) and replacement != [] do
    with {:ok, messages} <- decode_messages(replacement),
         :ok <- Transcript.validate_transcript(messages) do
      {:ok, payload}
    else
      {:error, reason} -> invalid_payload(reason)
    end
  end

  defp decode_payload(%{"type" => "reset"} = payload), do: {:ok, payload}

  defp decode_payload(
         %{
           "type" => "settings_snapshot",
           "model" => model,
           "thinking_level" => level,
           "workflow" => workflow,
           "system_prompt" => prompt
         } = payload
       )
       when (is_map(model) or is_nil(model)) and (is_binary(level) or is_nil(level)) and
              (is_binary(workflow) or is_nil(workflow)) and (is_binary(prompt) or is_nil(prompt)) do
    case decode_model(model) do
      :ok -> {:ok, payload}
      :error -> invalid_payload({:invalid_model, model})
    end
  end

  defp decode_payload(payload), do: {:error, {:invalid_event_payload, payload}}

  defp decode_messages(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn encoded, {:ok, acc} ->
      case Codec.decode(encoded) do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      {:error, _reason} = error -> error
    end)
  end

  defp invalid_payload(reason), do: {:error, {:invalid_event_payload, reason}}

  defp valid_settings?(settings) do
    match?(
      %{model: model, thinking_level: level, workflow: workflow, system_prompt: prompt}
      when (is_struct(model, Catalyst.Model) or is_nil(model)) and
             (is_binary(level) or is_nil(level)) and
             (is_binary(workflow) or is_nil(workflow)) and
             (is_binary(prompt) or is_nil(prompt)),
      settings
    )
  end

  defp encode_optional_message(nil), do: nil
  defp encode_optional_message(message), do: Codec.encode(message)
  defp encode_model(nil), do: nil
  defp encode_model(%Catalyst.Model{} = model), do: Codec.encode_model(model)

  defp decode_model(nil), do: :ok

  defp decode_model(model) do
    case Codec.decode_model(model) do
      {:ok, _model} -> :ok
      :error -> :error
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
