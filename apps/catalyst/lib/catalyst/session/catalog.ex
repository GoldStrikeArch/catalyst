defmodule Catalyst.Session.Catalog do
  @moduledoc """
  Persisted catalog of sessions, keyed by session id.

  `Catalyst.Session.Store` derives a transcript path from the `{cwd, id}`
  pair, so resuming a session after a full VM restart needs both halves.
  Live front ends typically remember only the id in VM-local state (the web
  shell keeps it in `:persistent_term`), which dies with the VM. The catalog
  persists `{id, cwd, last_used_at}` entries under `Catalyst.Paths.home/0`
  so any front end (the GUI today, CLI resume later) can rediscover the exact
  pair after a restart. Core-owned; no web dependencies.

  ## File format

  A single JSON document, most recently used entry first, replaced atomically
  via `Catalyst.Files.AtomicWrite`:

      {"version": 1,
       "entries": [{"id": "…", "cwd": "…", "last_used_at": "2026-07-23T…Z"}]}

  Entries whose session transcript no longer exists on disk are pruned on
  every read and rewrite. Reads of a corrupt catalog return tagged errors;
  `remember/2` self-heals by rewriting the file from scratch (the transcripts
  themselves are the durable source of truth).

  Override the location with `config :catalyst, :session_catalog_path`
  (defaults to `Catalyst.Paths.session_catalog/0`).
  """

  require Logger

  alias Catalyst.Files.AtomicWrite
  alias Catalyst.Session.Store

  @version 1

  @typedoc "One catalog entry (`last_used_at` is UTC ISO 8601)."
  @type entry :: %{id: String.t(), cwd: String.t(), last_used_at: String.t()}

  @typedoc "Tagged failures shared by the read/write API."
  @type error ::
          {:read_failed, File.posix()}
          | {:decode_failed, term()}
          | {:unsupported_catalog_version, term()}
          | {:encode_failed, term()}
          | {:mkdir_failed, File.posix()}
          | {:write_failed, term()}

  @doc "Path of the catalog file."
  @spec path() :: Path.t()
  def path do
    Application.get_env(:catalyst, :session_catalog_path) || Catalyst.Paths.session_catalog()
  end

  @doc """
  Upsert `{id, cwd}` as the most recently used session and persist the pruned
  catalog. An unreadable or corrupt existing catalog is logged and rebuilt
  rather than propagated, so one bad write can never disable resume forever.
  """
  @spec remember(String.t(), String.t()) :: :ok | {:error, error()}
  def remember(id, cwd) when is_binary(id) and is_binary(cwd) do
    entries = readable_entries()
    persist([new_entry(id, cwd) | Enum.reject(entries, &(&1.id == id))])
  end

  @doc "Remove `id` from the catalog (a missing entry is not an error)."
  @spec forget(String.t()) :: :ok | {:error, error()}
  def forget(id) when is_binary(id) do
    case entries() do
      {:ok, entries} -> persist(Enum.reject(entries, &(&1.id == id)))
      {:error, _reason} = error -> error
    end
  end

  @doc "All entries, most recently used first, pruned of deleted transcripts."
  @spec entries() :: {:ok, [entry()]} | {:error, error()}
  def entries do
    with {:ok, raw} <- read(path()),
         {:ok, decoded} <- decode(raw) do
      {:ok, prune(decoded)}
    end
  end

  @doc "The most recently used entry whose transcript still exists on disk."
  @spec most_recent() :: {:ok, entry()} | {:error, :empty} | {:error, error()}
  def most_recent do
    case entries() do
      {:ok, [entry | _rest]} -> {:ok, entry}
      {:ok, []} -> {:error, :empty}
      {:error, _reason} = error -> error
    end
  end

  @doc "The entry for `id`, if its transcript still exists on disk."
  @spec lookup(String.t()) :: {:ok, entry()} | {:error, :not_found} | {:error, error()}
  def lookup(id) when is_binary(id) do
    with {:ok, entries} <- entries() do
      case Enum.find(entries, &(&1.id == id)) do
        nil -> {:error, :not_found}
        entry -> {:ok, entry}
      end
    end
  end

  # ---- helpers --------------------------------------------------------------

  defp new_entry(id, cwd), do: %{id: id, cwd: cwd, last_used_at: now()}

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  defp readable_entries do
    case entries() do
      {:ok, entries} ->
        entries

      {:error, reason} ->
        Logger.warning("session catalog unreadable, rebuilding: #{inspect(reason)}")
        []
    end
  end

  defp prune(entries),
    do: Enum.filter(entries, fn %{id: id, cwd: cwd} -> File.regular?(Store.path_for(cwd, id)) end)

  defp persist(entries) do
    with {:ok, json} <- encode(prune(entries)),
         :ok <- ensure_dir(path()) do
      write(path(), json)
    end
  end

  defp encode(entries) do
    document = %{"version" => @version, "entries" => Enum.map(entries, &encode_entry/1)}

    case Jason.encode(document) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  defp encode_entry(%{id: id, cwd: cwd, last_used_at: at}),
    do: %{"id" => id, "cwd" => cwd, "last_used_at" => at}

  defp ensure_dir(path) do
    case path |> Path.dirname() |> File.mkdir_p() do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp write(path, json) do
    case AtomicWrite.write(path, json) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, :enoent} -> {:ok, :missing}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp decode(:missing), do: {:ok, []}

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, %{"version" => @version, "entries" => entries}} when is_list(entries) ->
        {:ok, decode_entries(entries)}

      {:ok, %{"version" => other}} ->
        {:error, {:unsupported_catalog_version, other}}

      {:ok, other} ->
        {:error, {:decode_failed, {:invalid_shape, other}}}

      {:error, reason} ->
        {:error, {:decode_failed, reason}}
    end
  end

  # Invalid entry shapes are dropped rather than failing the whole catalog:
  # each entry is independent and the transcripts remain the source of truth.
  defp decode_entries(entries) do
    for %{"id" => id, "cwd" => cwd} = entry <- entries, is_binary(id), is_binary(cwd) do
      %{id: id, cwd: cwd, last_used_at: timestamp_of(entry)}
    end
  end

  defp timestamp_of(%{"last_used_at" => at}) when is_binary(at), do: at
  defp timestamp_of(_entry), do: now()
end
