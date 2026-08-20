defmodule Catalyst.ACP.Protocol do
  @moduledoc """
  Minimal ACP v1 JSON-RPC encoding and boundary validation.
  """

  @type id :: integer() | String.t()
  @type message ::
          {:request, id(), String.t(), map()}
          | {:notification, String.t(), map()}
          | {:result, id(), term()}
          | {:error, id(), map()}

  @doc "Encode a JSON-RPC request as one NDJSON line."
  @spec request(id(), String.t(), map()) :: iodata()
  def request(id, method, params),
    do: encode(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

  @doc "Encode a JSON-RPC notification as one NDJSON line."
  @spec notification(String.t(), map()) :: iodata()
  def notification(method, params),
    do: encode(%{"jsonrpc" => "2.0", "method" => method, "params" => params})

  @doc "Encode a successful response."
  @spec result(id(), term()) :: iodata()
  def result(id, result), do: encode(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  @doc "Encode a method-not-found response."
  @spec method_not_found(id(), String.t()) :: iodata()
  def method_not_found(id, method) do
    encode(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "Method not found: #{method}"}
    })
  end

  @doc "Decode and validate one JSON-RPC line."
  @spec decode(binary()) :: {:ok, message()} | {:error, term()}
  def decode(line) when is_binary(line) do
    with {:ok, value} <- Jason.decode(line),
         {:ok, message} <- classify(value) do
      {:ok, message}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:malformed_json, error.position}}
      {:error, _reason} = error -> error
    end
  end

  defp classify(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = message)
       when (is_integer(id) or is_binary(id)) and is_binary(method) do
    with {:ok, params} <- params(message) do
      {:ok, {:request, id, method, params}}
    end
  end

  defp classify(%{"jsonrpc" => "2.0", "method" => method} = message) when is_binary(method) do
    with {:ok, params} <- params(message) do
      {:ok, {:notification, method, params}}
    end
  end

  defp classify(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
       when is_integer(id) or is_binary(id),
       do: {:ok, {:result, id, result}}

  defp classify(%{"jsonrpc" => "2.0", "id" => id, "error" => error})
       when (is_integer(id) or is_binary(id)) and is_map(error),
       do: {:ok, {:error, id, error}}

  defp classify(value) when is_list(value), do: {:error, :batches_not_supported}
  defp classify(value), do: {:error, {:invalid_jsonrpc, value}}

  defp params(message) do
    case Map.get(message, "params", %{}) do
      params when is_map(params) -> {:ok, params}
      invalid -> {:error, {:invalid_params, invalid}}
    end
  end

  defp encode(message), do: [Jason.encode_to_iodata!(message), "\n"]
end
