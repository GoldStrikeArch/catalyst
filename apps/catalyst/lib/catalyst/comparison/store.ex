defmodule Catalyst.Comparison.Store do
  @moduledoc """
  Atomic JSON persistence for comparison manifests.
  """

  alias Catalyst.Files.AtomicWrite

  @version 1
  @valid_id ~r/\A[A-Za-z0-9_-]+\z/

  @type manifest :: %{required(String.t()) => term()}

  @doc "Load one persisted comparison."
  @spec get(String.t()) :: {:ok, manifest()} | {:error, term()}
  def get(id) do
    with :ok <- validate_id(id),
         {:ok, contents} <- File.read(manifest_path(id)),
         {:ok, %{"version" => @version} = manifest} <- Jason.decode(contents) do
      {:ok, manifest}
    else
      {:error, :enoent} -> {:error, :comparison_not_found}
      {:ok, other} -> {:error, {:invalid_comparison_manifest, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "List persisted comparisons, newest first."
  @spec list() :: [manifest()]
  def list do
    root()
    |> Path.join("*/manifest.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case path |> File.read() |> decode_manifest() do
        {:ok, manifest} -> [manifest]
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort_by(&Map.get(&1, "updated_at", ""), :desc)
  end

  @doc "Atomically replace one comparison manifest."
  @spec persist(manifest()) :: :ok | {:error, term()}
  def persist(%{"id" => id} = manifest) do
    with :ok <- validate_id(id),
         {:ok, encoded} <- Jason.encode(manifest),
         :ok <- File.mkdir_p(dir(id)) do
      AtomicWrite.write(manifest_path(id), encoded)
    end
  end

  def persist(manifest), do: {:error, {:invalid_comparison_manifest, manifest}}

  @doc false
  @spec dir(String.t()) :: Path.t()
  def dir(id), do: Path.join(root(), id)

  @doc false
  @spec delete(String.t()) :: :ok
  def delete(id) do
    File.rm_rf(dir(id))
    :ok
  end

  defp decode_manifest({:ok, contents}) do
    case Jason.decode(contents) do
      {:ok, %{"version" => @version} = manifest} -> {:ok, manifest}
      {:ok, other} -> {:error, {:invalid_comparison_manifest, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_manifest({:error, reason}), do: {:error, reason}

  defp validate_id(id) when is_binary(id) do
    case Regex.match?(@valid_id, id) do
      true -> :ok
      false -> {:error, {:invalid_comparison_id, id}}
    end
  end

  defp validate_id(id), do: {:error, {:invalid_comparison_id, id}}

  defp manifest_path(id), do: Path.join(dir(id), "manifest.json")

  defp root,
    do: Application.get_env(:catalyst, :comparisons_root) || Catalyst.Paths.join("comparisons")
end
