defmodule Catalyst.Extensions.ModuleVersions do
  @moduledoc """
  Accepted BEAM version stacks and restoration for runtime extensions.

  Every accepted load retains its exact binaries. Failed partial compiles,
  rejected reloads, and uninstalls can therefore restore the last accepted
  extension version or the original module from the release code path.
  """

  require Logger

  @typedoc "One retained accepted module version."
  @type version :: %{owner: term(), path: Path.t(), beam: binary()}
  @type t :: %{optional(module()) => [version()]}

  @doc "Push all compiled binaries for an accepted owner version."
  @spec put(t(), term(), Path.t(), %{optional(module()) => binary()}) :: t()
  def put(module_versions, owner, path, beams) do
    module_versions
    |> drop_owner(owner)
    |> then(fn versions ->
      Enum.reduce(beams, versions, fn {module, beam}, acc ->
        version = %{owner: owner, path: path, beam: beam}
        Map.update(acc, module, [version], &[version | &1])
      end)
    end)
  end

  @doc "Remove one owner's retained versions from every module stack."
  @spec drop_owner(t(), term()) :: t()
  def drop_owner(module_versions, owner) do
    Enum.reduce(module_versions, %{}, fn {module, versions}, acc ->
      case Enum.reject(versions, &(&1.owner == owner)) do
        [] -> acc
        remaining -> Map.put(acc, module, remaining)
      end
    end)
  end

  @doc "Fetch exact accepted binaries for all of an owner's modules."
  @spec owner_beams([module()], term(), t()) ::
          {:ok, %{optional(module()) => binary()}} | :error
  def owner_beams(modules, owner, module_versions) do
    Enum.reduce_while(modules, {:ok, %{}}, fn module, {:ok, acc} ->
      case module_versions |> Map.get(module, []) |> Enum.find(&(&1.owner == owner)) do
        %{beam: beam} -> {:cont, {:ok, Map.put(acc, module, beam)}}
        nil -> {:halt, :error}
      end
    end)
  end

  @doc "Restore compiler-emitted candidate modules after a failed or rejected load."
  @spec restore_candidates([module()], t(), String.t()) :: :ok
  def restore_candidates(candidates, module_versions, context) do
    candidates
    |> Enum.uniq()
    |> Enum.each(fn module ->
      Logger.warning("[extensions] restoring #{inspect(module)} after #{context}")
      restore_current(module, module_versions)
    end)
  end

  @doc "Restore a removed module only when the purged owner was its active version."
  @spec restore_removed(module(), term(), t(), t()) :: :ok
  def restore_removed(module, owner, old_versions, new_versions) do
    case Map.get(old_versions, module, []) do
      [%{owner: ^owner} | _rest] -> restore_current(module, new_versions)
      _not_active -> :ok
    end
  end

  @doc "Load a map of exact binaries from one accepted source path."
  @spec load_beams(Path.t(), %{optional(module()) => binary()}) ::
          :ok | {:error, %{optional(module()) => term()}}
  def load_beams(path, beams) do
    results =
      Enum.reduce(beams, %{}, fn {module, beam}, acc ->
        :code.purge(module)

        case :code.load_binary(module, String.to_charlist(path), beam) do
          {:module, ^module} -> acc
          {:error, reason} -> Map.put(acc, module, reason)
        end
      end)

    if results == %{} do
      :ok
    else
      {:error, results}
    end
  end

  @doc "Restore the active accepted version, or the release-code version when none remains."
  @spec restore_current(module(), t()) :: :ok
  def restore_current(module, module_versions) do
    case Map.get(module_versions, module, []) do
      [version | _rest] -> load_version(module, version)
      [] -> restore_original(module)
    end
  end

  defp load_version(module, %{path: path, beam: beam}) do
    purge(module)

    case :code.load_binary(module, String.to_charlist(path), beam) do
      {:module, ^module} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[extensions] could not restore accepted BEAM for #{inspect(module)}: " <>
            inspect(reason)
        )

        restore_original(module)
    end
  catch
    kind, reason ->
      Logger.error(
        "[extensions] restoring accepted BEAM for #{inspect(module)} #{kind}: #{inspect(reason)}"
      )

      restore_original(module)
  end

  defp restore_original(module) do
    purge(module)

    case :code.load_file(module) do
      {:module, ^module} ->
        Logger.info("[extensions] restored original #{inspect(module)}")

      {:error, :nofile} ->
        :ok

      {:error, reason} ->
        Logger.warning("[extensions] could not restore #{inspect(module)}: #{inspect(reason)}")
    end
  catch
    kind, reason ->
      Logger.warning("[extensions] purging #{inspect(module)} #{kind}: #{inspect(reason)}")
  end

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end
end
