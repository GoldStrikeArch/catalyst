defmodule Catalyst.Runtime.IsolatedWorker.Protocol do
  @moduledoc """
  Version-one bounded wire format for isolated permission workers.

  Requests carry an Erlang external-term payload inside JSON. Decoding that
  payload is permitted only in the disposable worker VM. Host responses expose
  only the fixed permission-decision vocabulary and JSON data, so worker output
  cannot create atoms in the host VM.
  """

  @version 1

  @doc false
  @spec request(non_neg_integer(), atom(), [term()], pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def request(id, callback, args, limit) do
    payload = :erlang.term_to_binary({callback, args})

    encode(
      %{
        "protocol" => @version,
        "id" => id,
        "type" => "call",
        "payload" => Base.encode64(payload)
      },
      limit
    )
  end

  @doc false
  @spec decode_request(binary(), pos_integer()) ::
          {:ok, non_neg_integer(), atom(), [term()]} | {:error, term()}
  def decode_request(line, limit) when byte_size(line) <= limit do
    with {:ok,
          %{
            "protocol" => @version,
            "id" => id,
            "type" => "call",
            "payload" => payload
          }} <- Jason.decode(line),
         true <- is_integer(id) and id >= 0,
         {:ok, bytes} <- Base.decode64(payload),
         true <- byte_size(bytes) <= limit,
         {:authorize, [action, principal, resource, context]} <- :erlang.binary_to_term(bytes),
         true <- Enum.all?([action, principal, resource, context], &is_map/1) do
      {:ok, id, :authorize, [action, principal, resource, context]}
    else
      _invalid -> {:error, :invalid_isolated_worker_request}
    end
  rescue
    ArgumentError -> {:error, :invalid_isolated_worker_request}
  end

  def decode_request(_line, _limit), do: {:error, :isolated_worker_request_limit}

  @doc false
  @spec ready(binary(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def ready(artifact_id, limit) do
    encode(
      %{
        "protocol" => @version,
        "type" => "ready",
        "artifact" => artifact_id
      },
      limit
    )
  end

  @doc false
  @spec boot_error(term(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def boot_error(reason, limit) do
    encode(
      %{
        "protocol" => @version,
        "type" => "error",
        "reason" => inspect(reason, limit: 20, printable_limit: 2_048)
      },
      limit
    )
  end

  @doc false
  @spec response(non_neg_integer() | nil, term(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def response(id, result, limit) do
    result
    |> response_body(id)
    |> encode(limit)
  end

  @doc false
  @spec decode_ready(binary(), binary()) :: :ok | {:error, term()}
  def decode_ready(line, expected_artifact) do
    case Jason.decode(line) do
      {:ok,
       %{
         "protocol" => @version,
         "type" => "ready",
         "artifact" => ^expected_artifact
       }} ->
        :ok

      {:ok, %{"protocol" => @version, "type" => "error", "reason" => reason}} ->
        {:error, {:isolated_worker_boot_failed, reason}}

      _invalid ->
        {:error, :invalid_isolated_worker_ready}
    end
  end

  @doc false
  @spec decode_response(binary(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def decode_response(line, expected_id) do
    case Jason.decode(line) do
      {:ok, %{"protocol" => @version, "id" => ^expected_id, "status" => "allow"}} ->
        {:ok, :allow}

      {:ok,
       %{
         "protocol" => @version,
         "id" => ^expected_id,
         "status" => "deny",
         "reason" => reason
       }} ->
        {:ok, {:deny, reason}}

      {:ok,
       %{
         "protocol" => @version,
         "id" => ^expected_id,
         "status" => "challenge",
         "challenge" => challenge
       }}
      when is_map(challenge) ->
        {:ok, {:challenge, challenge}}

      {:ok,
       %{"protocol" => @version, "id" => ^expected_id, "status" => "error", "reason" => reason}} ->
        {:error, {:isolated_worker_call_failed, reason}}

      _invalid ->
        {:error, :invalid_isolated_worker_response}
    end
  end

  defp response_body(:allow, id),
    do: %{"protocol" => @version, "id" => id, "status" => "allow"}

  defp response_body({:deny, reason}, id) do
    %{
      "protocol" => @version,
      "id" => id,
      "status" => "deny",
      "reason" => inspect(reason, limit: 20, printable_limit: 2_048)
    }
  end

  defp response_body({:challenge, challenge}, id) when is_map(challenge) do
    %{
      "protocol" => @version,
      "id" => id,
      "status" => "challenge",
      "challenge" => challenge
    }
  end

  defp response_body({:error, reason}, id) do
    %{
      "protocol" => @version,
      "id" => id,
      "status" => "error",
      "reason" => inspect(reason, limit: 20, printable_limit: 2_048)
    }
  end

  defp response_body(result, id), do: response_body({:error, {:invalid_decision, result}}, id)

  defp encode(value, limit) do
    with {:ok, encoded} <- Jason.encode(value),
         encoded = encoded <> "\n",
         true <- byte_size(encoded) <= limit do
      {:ok, encoded}
    else
      false -> {:error, :isolated_worker_response_limit}
      {:error, reason} -> {:error, {:isolated_worker_encode_failed, reason}}
    end
  end
end
