defmodule Catalyst.LLM.OpenAICodex.BoundedBuffer do
  @moduledoc false

  @default_limit 65_536

  defstruct chunks: [], bytes: 0, limit: @default_limit

  @type t :: %__MODULE__{
          chunks: [binary()],
          bytes: non_neg_integer(),
          limit: non_neg_integer()
        }

  @doc false
  @spec new(non_neg_integer()) :: t()
  def new(limit \\ @default_limit) when is_integer(limit) and limit >= 0,
    do: %__MODULE__{limit: limit}

  @doc false
  @spec append(t(), binary()) :: t()
  def append(%__MODULE__{} = buffer, chunk) when is_binary(chunk) do
    size = min(byte_size(chunk), buffer.limit - buffer.bytes)

    case size do
      0 -> buffer
      _positive -> prepend(buffer, binary_part(chunk, 0, size))
    end
  end

  @doc false
  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{} = buffer) do
    buffer.chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  @spec prepend(t(), binary()) :: t()
  defp prepend(%__MODULE__{} = buffer, chunk) do
    %__MODULE__{buffer | chunks: [chunk | buffer.chunks], bytes: buffer.bytes + byte_size(chunk)}
  end
end
