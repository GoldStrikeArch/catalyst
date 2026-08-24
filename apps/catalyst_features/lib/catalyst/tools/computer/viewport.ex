defmodule Catalyst.Tools.Computer.Viewport do
  @moduledoc """
  Per-session record of the last screenshot's coordinate geometry.

  The model addresses the screen in the **pixel space of its most recent
  screenshot**; posting input requires mapping those pixels back to global
  display points (`Catalyst.Tools.Computer.Capture.to_point/4`). Tool calls run
  in fresh tasks, so the geometry of the last capture — display/window origin
  in points, backing scale, and downscale ratio — is kept here, in a public ETS
  table owned by this small supervised GenServer.

  The GenServer exists purely to be a **stable table owner**: when the table
  belonged to `Catalyst.Tools.Computer.Helper`, a Helper crash destroyed every
  session's recorded geometry and the next click silently fell back to the
  default main-display viewport — badly wrong after a window-scoped screenshot.
  This process does nothing else, so it should never crash and the geometry
  survives helper churn.

  The table is **bounded**: only the most recently written
  #{64} session entries are kept (writes stamp a monotonic counter; the oldest
  entries are evicted past the bound), so long-lived hosts do not accumulate
  dead sessions' geometry forever. Writes go through the GenServer to keep the
  eviction race-free; reads hit ETS directly.

  A session with no entry — never screenshotted, evicted, or restarted (the
  table is rebuilt empty at boot while screenshots persist in the transcript)
  — has no usable geometry. `Catalyst.Tools.Computer` fails coordinate-taking
  actions closed on a miss, demanding a fresh screenshot; missing geometry is
  never substituted with a guess.
  """

  use GenServer

  @table :catalyst_computer_viewport
  @default_max_entries 64

  @typedoc "Last-capture geometry: origin in points, backing scale, downscale ratio."
  @type t :: %{origin: {number(), number()}, scale: number(), ratio: number()}

  @doc """
  Start the viewport table owner. Options: `:name` (default
  `#{inspect(__MODULE__)}`, `nil` for an unnamed test instance), `:table`
  (ETS table name, default `#{inspect(@table)}`), `:max_entries` (eviction
  bound, default #{@default_max_entries}).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Record the viewport for a session key (any term; session id in practice)."
  @spec put(term(), t()) :: :ok
  def put(session_key, viewport), do: put(__MODULE__, session_key, viewport)

  @doc "Record the viewport through a specific owner (test instances)."
  @spec put(GenServer.server(), term(), t()) :: :ok
  def put(server, session_key, %{origin: {_, _}, scale: scale, ratio: ratio} = viewport)
      when is_number(scale) and is_number(ratio) do
    GenServer.call(server, {:put, session_key, viewport})
  catch
    # The owner being down (start/stop races in tests) degrades to "no record":
    # the next coordinate-taking action fails closed and demands a fresh
    # screenshot, same as before any screenshot exists.
    :exit, _reason -> :ok
  end

  @doc "The recorded viewport for a session key."
  @spec fetch(term()) :: {:ok, t()} | :error
  def fetch(session_key), do: fetch_from(@table, session_key)

  @doc "The recorded viewport from a specific table (test instances)."
  @spec fetch_from(atom(), term()) :: {:ok, t()} | :error
  def fetch_from(table, session_key) do
    case :ets.whereis(table) do
      :undefined -> :error
      _tid -> lookup(table, session_key)
    end
  end

  defp lookup(table, session_key) do
    case :ets.lookup(table, session_key) do
      [{^session_key, viewport, _stamp}] -> {:ok, viewport}
      [] -> :error
    end
  end

  # ---- GenServer ------------------------------------------------------------

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    table = :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

    {:ok, %{table: table, max_entries: Keyword.get(opts, :max_entries, @default_max_entries)}}
  end

  @impl true
  def handle_call({:put, session_key, viewport}, _from, state) do
    :ets.insert(state.table, {session_key, viewport, :erlang.unique_integer([:monotonic])})
    evict_oldest(state)
    {:reply, :ok, state}
  end

  defp evict_oldest(%{table: table, max_entries: max_entries}) do
    case :ets.info(table, :size) - max_entries do
      overflow when overflow > 0 ->
        table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {_key, _viewport, stamp} -> stamp end)
        |> Enum.take(overflow)
        |> Enum.each(fn {key, _viewport, _stamp} -> :ets.delete(table, key) end)

      _within_bound ->
        :ok
    end
  end
end
