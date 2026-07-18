defmodule CatalystWeb.UI.Contributions do
  @moduledoc """
  Stable replay log for live UI extension contributions.

  The log is serialized by this GenServer and mirrored in `:persistent_term`,
  so it survives both the UI ETS owner and this process restarting. Registry
  recovery re-inserts these exact entries; it never recompiles source files or
  re-runs arbitrary extension setup callbacks.
  """

  use GenServer

  @storage_key {__MODULE__, :entries}

  @type entry :: {term(), map()}

  @doc "Start the singleton contribution log."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Record one live registry entry."
  @spec record(term(), map()) :: :ok
  def record(key, entry), do: GenServer.call(__MODULE__, {:record, key, entry})

  @doc "Remove every recorded contribution for an extension owner."
  @spec drop_owner(term()) :: :ok
  def drop_owner(owner) do
    GenServer.call(__MODULE__, {:drop_owner, owner})
  catch
    :exit, _reason -> drop_persisted_owner(owner)
  end

  @doc "Snapshot entries in original registration order."
  @spec list() :: [entry()]
  def list, do: GenServer.call(__MODULE__, :list)

  @impl true
  def init(:ok), do: {:ok, :ok}

  @impl true
  def handle_call({:record, key, entry}, _from, state) do
    entries = record_entry(persisted_entries(), key, entry)
    persist(entries)
    {:reply, :ok, state}
  end

  def handle_call({:drop_owner, owner}, _from, state) do
    :ok = drop_persisted_owner(owner)
    {:reply, :ok, state}
  end

  def handle_call(:list, _from, state) do
    entries = persisted_entries()
    {:reply, Enum.sort_by(entries, fn {_key, entry} -> Map.get(entry, :seq, -1) end), state}
  end

  defp record_entry(entries, key, entry) do
    case singleton_key?(key) do
      true -> [{key, entry} | Enum.reject(entries, fn {existing, _entry} -> existing == key end)]
      false -> [{key, entry} | entries]
    end
  end

  defp singleton_key?({kind, _key}) when kind in [:page, :command], do: true
  defp singleton_key?(_key), do: false

  defp persist(entries) do
    :persistent_term.put(@storage_key, entries)
    :ok
  end

  defp drop_persisted_owner(owner) do
    persisted_entries()
    |> Enum.reject(fn {_key, entry} -> Map.get(entry, :owner) == owner end)
    |> persist()
  end

  defp persisted_entries do
    case :persistent_term.get(@storage_key, []) do
      entries when is_list(entries) -> entries
      _invalid -> []
    end
  end
end
