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
         {:ok, manifest} <- decode_manifest(contents, id) do
      {:ok, manifest}
    else
      {:error, :enoent} -> {:error, :comparison_not_found}
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
      id = path |> Path.dirname() |> Path.basename()

      case path |> File.read() |> decode_manifest(id) do
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
         :ok <- validate_manifest(manifest, id),
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

  defp decode_manifest({:ok, contents}, expected_id), do: decode_manifest(contents, expected_id)
  defp decode_manifest({:error, reason}, _expected_id), do: {:error, reason}

  defp decode_manifest(contents, expected_id) when is_binary(contents) do
    with {:ok, manifest} <- Jason.decode(contents),
         :ok <- validate_manifest(manifest, expected_id) do
      {:ok, manifest}
    end
  end

  defp validate_manifest(
         %{
           "version" => @version,
           "id" => id,
           "title" => title,
           "source_root" => source_root,
           "system_prompt" => system_prompt,
           "snapshots" => snapshots,
           "lanes" => lanes,
           "inserted_at" => inserted_at,
           "updated_at" => updated_at
         } = manifest,
         expected_id
       )
       when id == expected_id and is_binary(title) and title != "" and is_binary(source_root) and
              source_root != "" and is_binary(system_prompt) and is_map(snapshots) and
              map_size(snapshots) > 0 and is_list(lanes) and length(lanes) >= 2 and
              is_binary(inserted_at) and is_binary(updated_at) do
    with :ok <- validate_id(id),
         :ok <- validate_snapshots(snapshots),
         :ok <- validate_lanes(lanes, snapshots) do
      :ok
    else
      {:error, _reason} -> invalid_manifest(manifest)
    end
  end

  defp validate_manifest(manifest, _expected_id), do: invalid_manifest(manifest)

  defp validate_snapshots(snapshots) do
    valid? =
      Enum.all?(snapshots, fn
        {id,
         %{
           "id" => id,
           "revision" => revision,
           "digest" => digest,
           "untracked_paths" => paths,
           "captured_at" => captured_at
         }} ->
          valid_id?(id) and is_binary(revision) and revision != "" and is_binary(digest) and
            digest != "" and is_list(paths) and Enum.all?(paths, &is_binary/1) and
            is_binary(captured_at)

        _invalid ->
          false
      end)

    valid_or_error(valid?)
  end

  defp validate_lanes(lanes, snapshots) do
    valid? =
      Enum.all?(lanes, &valid_lane?(&1, snapshots)) and
        unique_field?(lanes, "id") and
        unique_field?(lanes, "workspace_id") and
        unique_field?(lanes, "session_id")

    valid_or_error(valid?)
  end

  defp valid_lane?(
         %{
           "id" => id,
           "workspace_id" => workspace_id,
           "cwd" => cwd,
           "session_id" => session_id,
           "snapshot_id" => snapshot_id,
           "model_id" => model_id,
           "system_prompt" => system_prompt,
           "created_at" => created_at
         } = lane,
         snapshots
       ) do
    valid_id?(id) and valid_id?(workspace_id) and is_binary(cwd) and cwd != "" and
      valid_id?(session_id) and Map.has_key?(snapshots, snapshot_id) and is_binary(model_id) and
      model_id != "" and is_binary(system_prompt) and is_binary(created_at) and
      optional_binary?(Map.get(lane, "reasoning_effort")) and
      optional_binary?(Map.get(lane, "workflow"))
  end

  defp valid_lane?(_lane, _snapshots), do: false

  defp unique_field?(items, field) do
    values = Enum.map(items, &Map.fetch!(&1, field))
    length(values) == length(Enum.uniq(values))
  end

  defp optional_binary?(nil), do: true
  defp optional_binary?(value), do: is_binary(value)
  defp valid_or_error(true), do: :ok
  defp valid_or_error(false), do: {:error, :invalid}
  defp invalid_manifest(manifest), do: {:error, {:invalid_comparison_manifest, manifest}}

  defp validate_id(id) when is_binary(id) do
    case valid_id?(id) do
      true -> :ok
      false -> {:error, {:invalid_comparison_id, id}}
    end
  end

  defp validate_id(id), do: {:error, {:invalid_comparison_id, id}}
  defp valid_id?(id) when is_binary(id), do: Regex.match?(@valid_id, id)
  defp valid_id?(_id), do: false

  defp manifest_path(id), do: Path.join(dir(id), "manifest.json")

  defp root,
    do: Application.get_env(:catalyst, :comparisons_root) || Catalyst.Paths.join("comparisons")
end
