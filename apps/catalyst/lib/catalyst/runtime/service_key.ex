defmodule Catalyst.Runtime.ServiceKey do
  @moduledoc """
  Stable logical identity of one replaceable runtime service.

  Service keys are data rather than module names. The `namespace` and `name`
  identify the service contract, while `slot` selects one named implementation
  family such as the default run engine or a named workflow.
  """

  @enforce_keys [:namespace, :name, :slot]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          namespace: String.t(),
          name: String.t(),
          slot: String.t()
        }

  @doc "Build a validated service key."
  @spec new(String.t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def new(namespace, name, slot \\ "default") do
    with {:ok, namespace} <- validate_part(:namespace, namespace),
         {:ok, name} <- validate_part(:name, name),
         {:ok, slot} <- validate_part(:slot, slot) do
      {:ok, %__MODULE__{namespace: namespace, name: name, slot: slot}}
    end
  end

  @doc "Build a service key, raising `ArgumentError` when a part is invalid."
  @spec new!(String.t(), String.t(), String.t()) :: t()
  def new!(namespace, name, slot \\ "default") do
    case new(namespace, name, slot) do
      {:ok, key} -> key
      {:error, reason} -> raise ArgumentError, "invalid service key: #{inspect(reason)}"
    end
  end

  @doc "Return the stable wire representation `namespace.name/slot`."
  @spec to_wire(t()) :: String.t()
  def to_wire(%__MODULE__{} = key), do: "#{key.namespace}.#{key.name}/#{key.slot}"

  @doc "Parse the stable `namespace.name/slot` wire representation."
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(value) when is_binary(value) do
    with [qualified, slot] <- String.split(value, "/", parts: 2),
         [namespace, name] <- String.split(qualified, ".", parts: 2) do
      new(namespace, name, slot)
    else
      _invalid -> {:error, {:invalid_service_key, value}}
    end
  end

  def parse(value), do: {:error, {:invalid_service_key, value}}

  defp validate_part(part, value) when is_binary(value) and byte_size(value) > 0 do
    cond do
      String.trim(value) == "" ->
        {:error, {:invalid_service_key_part, part, value}}

      part != :slot and String.trim(value) != value ->
        {:error, {:invalid_service_key_part, part, value}}

      part != :slot and String.contains?(value, "/") ->
        {:error, {:invalid_service_key_part, part, value}}

      part == :namespace and String.contains?(value, ".") ->
        {:error, {:invalid_service_key_part, part, value}}

      true ->
        {:ok, value}
    end
  end

  defp validate_part(part, value), do: {:error, {:invalid_service_key_part, part, value}}
end
