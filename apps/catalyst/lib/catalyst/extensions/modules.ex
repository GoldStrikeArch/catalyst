defmodule Catalyst.Extensions.Modules do
  @moduledoc """
  Loads staged extension BEAMs and restores the release-code baseline.

  Accepted extension binaries are derived from source on every rebuild. The
  current contribution may cache its binaries as part of the reconstructible
  runtime projection; there is no version stack or durable code history.
  """

  require Logger

  @doc "Load every compiled module binary from one source file."
  @spec load(Path.t(), %{optional(module()) => binary()}) ::
          :ok | {:error, %{optional(module()) => term()}}
  def load(path, beams) do
    failures =
      Enum.reduce(beams, %{}, fn {module, beam}, acc ->
        purge(module)

        case :code.load_binary(module, String.to_charlist(path), beam) do
          {:module, ^module} -> acc
          {:error, reason} -> Map.put(acc, module, reason)
        end
      end)

    case failures do
      empty when map_size(empty) == 0 -> :ok
      failures -> {:error, failures}
    end
  end

  @doc "Restore a module from the release code path, or remove it when none exists."
  @spec restore_original(module()) :: :ok
  def restore_original(module) do
    purge(module)

    case :code.load_file(module) do
      {:module, ^module} ->
        :ok

      {:error, :nofile} ->
        :ok

      {:error, reason} ->
        Logger.warning("could not restore #{inspect(module)}: #{inspect(reason)}")
    end
  catch
    kind, reason ->
      Logger.warning("restoring #{inspect(module)} #{kind}: #{inspect(reason)}")
  end

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end
end
