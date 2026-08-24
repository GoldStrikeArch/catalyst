defmodule Catalyst.WorkflowRun.Store do
  @moduledoc """
  Atomic JSON checkpoint storage for durable workflow runs.

  Each run owns one `<id>.json` file below `Catalyst.Paths.workflow_runs/0`.
  """

  alias Catalyst.Files.AtomicWrite

  @valid_id ~r/\A[A-Za-z0-9_-]+\z/

  @doc "Return the configured checkpoint root."
  @spec root() :: Path.t()
  def root,
    do: Application.get_env(:catalyst, :workflow_runs_root) || Catalyst.Paths.workflow_runs()

  @doc "Return a validated checkpoint path."
  @spec path(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def path(id) when is_binary(id) do
    case Regex.match?(@valid_id, id) do
      true -> {:ok, Path.join(root(), id <> ".json")}
      false -> {:error, {:invalid_workflow_run_id, id}}
    end
  end

  def path(id), do: {:error, {:invalid_workflow_run_id, id}}

  @doc "Atomically write a JSON-safe checkpoint."
  @spec put(map()) :: :ok | {:error, term()}
  def put(%{"id" => id} = checkpoint) do
    with {:ok, path} <- path(id),
         {:ok, json} <- encode(checkpoint),
         :ok <- mkdir(),
         :ok <- atomic_write(path, json) do
      :ok
    end
  end

  def put(checkpoint), do: {:error, {:invalid_checkpoint, checkpoint}}

  @doc "Load one checkpoint."
  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(id) do
    with {:ok, path} <- path(id),
         {:ok, bytes} <- read(path),
         {:ok, checkpoint} <- decode(path, bytes) do
      {:ok, checkpoint}
    end
  end

  @doc "List valid checkpoints in stable newest-first order."
  @spec list() :: [map()]
  def list do
    root()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(&load_path/1)
    |> Enum.sort_by(&Map.get(&1, "updated_at", ""), :desc)
  end

  @doc "Mark checkpoints left running by a previous application instance interrupted."
  @spec interrupt_all() :: :ok
  def interrupt_all do
    list()
    |> Enum.filter(&(Map.get(&1, "status") == "running"))
    |> Enum.each(&interrupt/1)

    :ok
  end

  defp interrupt(checkpoint) do
    checkpoint
    |> Map.put("status", "interrupted")
    |> Map.put("updated_at", timestamp())
    |> put()
  end

  defp load_path(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, checkpoint} <- decode(path, bytes) do
      [checkpoint]
    else
      _error -> []
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, :workflow_run_not_found}
      {:error, reason} -> {:error, {:read_checkpoint, path, reason}}
    end
  end

  defp decode(path, bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = checkpoint} -> {:ok, checkpoint}
      {:ok, value} -> {:error, {:invalid_checkpoint, path, value}}
      {:error, reason} -> {:error, {:decode_checkpoint, path, reason}}
    end
  end

  defp encode(checkpoint) do
    case Jason.encode(checkpoint) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:encode_checkpoint, reason}}
    end
  end

  defp mkdir do
    case File.mkdir_p(root()) do
      :ok -> :ok
      {:error, reason} -> {:error, {:create_workflow_runs_directory, root(), reason}}
    end
  end

  defp atomic_write(path, json) do
    case AtomicWrite.write(path, json, mode: 0o600) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_checkpoint, path, reason}}
    end
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
