defmodule Catalyst.Ids do
  @moduledoc "Cryptographically strong identifiers used at internal boundaries."

  @doc "Generate `bytes` random bytes encoded as lowercase hexadecimal."
  @spec hex(pos_integer()) :: String.t()
  def hex(bytes) when is_integer(bytes) and bytes > 0 do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
