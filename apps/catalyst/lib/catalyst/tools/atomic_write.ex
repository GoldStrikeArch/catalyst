defmodule Catalyst.Tools.AtomicWrite do
  @moduledoc """
  Compatibility facade for `Catalyst.Files.AtomicWrite`.

  New cross-domain callers should use the shared module directly.
  """

  @doc "See `Catalyst.Files.AtomicWrite.write/3`."
  @spec write(Path.t(), iodata(), keyword()) :: :ok | {:error, term()}
  defdelegate write(path, content, opts \\ []), to: Catalyst.Files.AtomicWrite

  @doc "See `Catalyst.Files.AtomicWrite.write!/3`."
  @spec write!(Path.t(), iodata(), keyword()) :: :ok
  defdelegate write!(path, content, opts \\ []), to: Catalyst.Files.AtomicWrite
end
