defmodule Catalyst.Runtime.Registry do
  @moduledoc """
  The single owner-aware store for live runtime contributions.

  Domain modules remain responsible for validating values and resolving their
  application, file, and built-in fallback layers. This registry owns only the
  behavior every runtime extension point shares: collision-safe writes, direct
  reads, stable listing, and owner-wide removal.

  Rows are keyed by `{kind, key}` and contain the normalized owner and opaque
  value. The table is intentionally reconstructible: accepted extension
  sources are durable state, while this process is their live projection.
  Reads return `:error` while the process is unavailable so domain resolvers can
  continue through their documented fallback layers.
  """

  use GenServer

  @table :catalyst_runtime_contributions

  @type kind :: atom()
  @type key :: term()
  @type entry :: %{kind: kind(), key: key(), owner: term(), value: term()}

  @doc "Start the singleton contribution registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Register or refresh one contribution.

  The same owner may replace its value. A different owner receives the common
  `{:owner_collision, kind, key, existing, attempted}` error. Use
  `:collision_key` when a domain's public key differs from its storage key.
  """
  @spec put(kind(), key(), term(), keyword()) :: :ok | {:error, term()}
  def put(kind, key, value, opts \\ []) when is_atom(kind) and is_list(opts) do
    GenServer.call(__MODULE__, {:put, kind, key, value, opts})
  end

  @doc "Remove one contribution regardless of owner."
  @spec delete(kind(), key()) :: :ok
  def delete(kind, key) when is_atom(kind) do
    GenServer.call(__MODULE__, {:delete, kind, key})
  end

  @doc "Remove every contribution currently attributed to `owner`."
  @spec purge_owner(term()) :: :ok
  def purge_owner(owner), do: GenServer.call(__MODULE__, {:purge_owner, owner, :all})

  @doc "Remove `owner` contributions for one kind or a list of kinds."
  @spec purge_owner(term(), kind() | [kind()]) :: :ok
  def purge_owner(owner, kinds) when is_atom(kinds) or is_list(kinds) do
    GenServer.call(__MODULE__, {:purge_owner, owner, List.wrap(kinds)})
  end

  @doc "Fetch one contribution with its owner."
  @spec fetch(kind(), key()) :: {:ok, term(), term()} | :error
  def fetch(kind, key) when is_atom(kind) do
    case lookup({kind, key}) do
      [{{^kind, ^key}, owner, value}] -> {:ok, value, owner}
      _missing -> :error
    end
  end

  @doc "Whether the live contribution table is currently available."
  @spec available?() :: boolean()
  def available?, do: :ets.whereis(@table) != :undefined

  @doc "Normalize a missing host owner to the reserved `:host` id."
  @spec normalize_owner(term()) :: term()
  def normalize_owner(nil), do: :host
  def normalize_owner(owner), do: owner

  @doc "List one kind's contributions in stable key order."
  @spec list(kind()) :: [entry()]
  def list(kind) when is_atom(kind) do
    kind
    |> match()
    |> Enum.map(fn {{^kind, key}, owner, value} ->
      %{kind: kind, key: key, owner: owner, value: value}
    end)
    |> Enum.sort_by(&inspect(&1.key))
  end

  @doc "List every live contribution in stable kind/key order."
  @spec list_all() :: [entry()]
  def list_all do
    @table
    |> tab2list()
    |> Enum.map(fn {{kind, key}, owner, value} ->
      %{kind: kind, key: key, owner: owner, value: value}
    end)
    |> Enum.sort_by(&{&1.kind, inspect(&1.key)})
  end

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, :ok}
  end

  @impl true
  def handle_call({:put, kind, key, value, opts}, _from, state) do
    owner = opts |> Keyword.get(:owner) |> normalize_owner()
    collision_key = Keyword.get(opts, :collision_key, key)

    case fetch(kind, key) do
      :error ->
        insert(kind, key, owner, value)
        {:reply, :ok, state}

      {:ok, _previous, ^owner} ->
        insert(kind, key, owner, value)
        {:reply, :ok, state}

      {:ok, _previous, existing} ->
        collision = {:owner_collision, kind, collision_key, existing, owner}
        {:reply, {:error, collision}, state}
    end
  end

  def handle_call({:delete, kind, key}, _from, state) do
    :ets.delete(@table, {kind, key})
    {:reply, :ok, state}
  end

  def handle_call({:purge_owner, owner, :all}, _from, state) do
    :ets.match_delete(@table, {{:_, :_}, owner, :_})
    {:reply, :ok, state}
  end

  def handle_call({:purge_owner, owner, kinds}, _from, state) do
    Enum.each(kinds, &:ets.match_delete(@table, {{&1, :_}, owner, :_}))
    {:reply, :ok, state}
  end

  defp insert(kind, key, owner, value),
    do: :ets.insert(@table, {{kind, key}, owner, value})

  defp lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  defp match(kind) do
    :ets.match_object(@table, {{kind, :_}, :_, :_})
  rescue
    ArgumentError -> []
  end

  defp tab2list(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end
end
