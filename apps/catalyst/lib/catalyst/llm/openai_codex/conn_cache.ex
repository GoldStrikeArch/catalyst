defmodule Catalyst.LLM.OpenAICodex.ConnCache do
  @moduledoc """
  Holds idle Codex websocket connections BETWEEN turns and runs, keyed by
  session id, so the connection-scoped `previous_response_id` continuation
  (delta uploads, §6) survives run boundaries — turn 1 of the next prompt
  rides a delta instead of re-uploading the transcript.

  Ownership model: while a turn streams, the run task owns the socket (as
  before — aborting the run kills both). Around the idle gaps the socket is
  transferred here with `Mint.HTTP.controlling_process/2`; this process
  answers server pings and evicts entries whose socket closes (the server
  enforces a 60-minute connection lifetime — eviction just means the next
  checkout reconnects and does one full upload).

  Idle entries have a local monotonic TTL and the cache retains at most a
  configured number of sockets. The defaults are ten minutes and 32 entries;
  override them with `config :catalyst, :codex_conn_cache_idle_ttl_ms` and
  `config :catalyst, :codex_conn_cache_max_entries`.

  Transfer caveat: socket messages already sitting in the previous owner's
  mailbox at hand-off are lost. Under the idle-connection invariant, only
  pings/closes should be in flight: a missed close is detected on the next
  checkout/open/send path, which then attempts one fresh connection and full
  upload. Recovery therefore happens on next use and still depends on that
  fresh connection succeeding.
  """

  use GenServer

  require Logger

  alias Catalyst.LLM.OpenAICodex.WebSocket
  alias Catalyst.Tasks
  require WebSocket

  @default_idle_ttl_ms 600_000
  @default_max_entries 32

  @type continuation :: map() | nil
  @type server :: GenServer.server()

  @doc "Start the idle connection cache."
  @spec start_link() :: GenServer.on_start()
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Take the session's idle connection; ownership transfers to the caller.
  Returns `{:ok, conn, continuation}` or `:none` (no entry, url mismatch, or
  the cache is down — the caller connects fresh).
  """
  @spec checkout(String.t(), String.t()) :: {:ok, WebSocket.t(), continuation()} | :none
  @spec checkout(String.t(), String.t(), server()) ::
          {:ok, WebSocket.t(), continuation()} | :none
  def checkout(session_id, url, server \\ __MODULE__) do
    GenServer.call(server, {:checkout, session_id, url, self()})
  catch
    :exit, _reason -> :none
  end

  @doc "Whether an idle connection is cached for the session (used by prewarm)."
  @spec has?(String.t(), String.t()) :: boolean()
  @spec has?(String.t(), String.t(), server()) :: boolean()
  def has?(session_id, url, server \\ __MODULE__) do
    GenServer.call(server, {:has?, session_id, url})
  catch
    :exit, _reason -> false
  end

  @doc """
  Store an idle connection the CALLER currently owns. Transfers ownership to
  the cache; on any failure the socket is simply left to die with the caller.

  The cache reserves and monitors the hand-off before ownership moves. If the
  caller is killed between the Mint transfer and the commit call, the cache
  closes the reserved socket instead of leaking an untracked connection.
  """
  @spec stash(String.t(), String.t(), WebSocket.t(), continuation()) :: :ok
  def stash(session_id, url, %WebSocket{} = ws, continuation) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> transfer_stash(pid, session_id, url, ws, continuation)
      nil -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec stash_owned(String.t(), String.t(), WebSocket.t(), continuation()) :: :ok
  @spec stash_owned(String.t(), String.t(), WebSocket.t(), continuation(), keyword()) :: :ok
  def stash_owned(session_id, url, %WebSocket{} = ws, continuation, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:stash, session_id, url, ws, continuation})
  end

  @doc "Drop (and close) the session's cached connection, if any."
  @spec drop(String.t()) :: :ok
  @spec drop(String.t(), server()) :: :ok
  def drop(session_id, server \\ __MODULE__) do
    GenServer.call(server, {:drop, session_id})
  catch
    :exit, _reason -> :ok
  end

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(opts) do
    idle_ttl_ms =
      Keyword.get_lazy(opts, :idle_ttl_ms, fn ->
        Application.get_env(
          :catalyst,
          :codex_conn_cache_idle_ttl_ms,
          @default_idle_ttl_ms
        )
      end)

    max_entries =
      Keyword.get_lazy(opts, :max_entries, fn ->
        Application.get_env(:catalyst, :codex_conn_cache_max_entries, @default_max_entries)
      end)

    with :ok <- validate_idle_ttl(idle_ttl_ms),
         :ok <- validate_max_entries(max_entries) do
      {:ok,
       %{
         entries: %{},
         pending: %{},
         idle_ttl_ms: idle_ttl_ms,
         max_entries: max_entries,
         clock: Keyword.get(opts, :clock, &Tasks.monotonic_ms/0),
         close: Keyword.get(opts, :close, &WebSocket.close/1),
         sequence: 0,
         expiry_timer: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:checkout, session_id, url, caller}, _from, state) do
    state = evict_expired(state)

    case Map.pop(state.entries, session_id) do
      {nil, entries} ->
        {:reply, :none, reschedule_expiry(%{state | entries: entries})}

      {%{url: ^url, conn: ws, continuation: cont} = entry, entries} ->
        case Mint.HTTP.controlling_process(ws.conn, caller) do
          {:ok, mint_conn} ->
            state = reschedule_expiry(%{state | entries: entries})
            {:reply, {:ok, %{ws | conn: mint_conn}, cont}, state}

          {:error, _reason} ->
            close_entry(state, entry)
            {:reply, :none, reschedule_expiry(%{state | entries: entries})}
        end

      {entry, entries} ->
        # Different endpoint (model base_url changed) — stale, close it.
        close_entry(state, entry)
        {:reply, :none, reschedule_expiry(%{state | entries: entries})}
    end
  end

  def handle_call({:has?, session_id, url}, _from, state) do
    state = state |> evict_expired() |> reschedule_expiry()
    {:reply, match?(%{url: ^url}, state.entries[session_id]), state}
  end

  def handle_call({:prepare_stash, ws}, {owner, _tag}, state) do
    ref = make_ref()
    pending = %{conn: ws, monitor: Process.monitor(owner)}
    {:reply, {:ok, ref}, %{state | pending: Map.put(state.pending, ref, pending)}}
  end

  def handle_call({:commit_stash, ref, session_id, url, ws, continuation}, _from, state) do
    case Map.pop(state.pending, ref) do
      {nil, pending} ->
        {:reply, :ok, %{state | pending: pending}}

      {%{monitor: monitor}, pending} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | pending: pending}
        {:reply, :ok, store_entry(state, session_id, url, ws, continuation)}
    end
  end

  def handle_call({:abort_stash, ref}, _from, state) do
    case Map.pop(state.pending, ref) do
      {nil, pending} ->
        {:reply, :ok, %{state | pending: pending}}

      {%{monitor: monitor}, pending} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, %{state | pending: pending}}
    end
  end

  def handle_call({:stash, session_id, url, ws, continuation}, _from, state) do
    {:reply, :ok, store_entry(state, session_id, url, ws, continuation)}
  end

  def handle_call({:drop, session_id}, _from, state) do
    state = evict_expired(state)

    case Map.pop(state.entries, session_id) do
      {nil, entries} ->
        {:reply, :ok, reschedule_expiry(%{state | entries: entries})}

      {entry, entries} ->
        close_entry(state, entry)
        {:reply, :ok, reschedule_expiry(%{state | entries: entries})}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.entries, fn {_session_id, entry} -> close_entry(state, entry) end)
    close_all_pending(state)
  end

  # Socket traffic for idle connections: answer pings, evict on close/error.
  @impl true
  def handle_info(msg, state) when WebSocket.is_socket_message(msg) do
    state = state |> evict_expired() |> route_socket_message(msg) |> reschedule_expiry()
    {:noreply, state}
  end

  def handle_info({:expire_idle, token}, %{expiry_timer: {_timer, token}} = state) do
    state = %{state | expiry_timer: nil}
    {:noreply, state |> evict_expired() |> reschedule_expiry()}
  end

  def handle_info({:expire_idle, _stale_token}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, close_pending(state, monitor)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp transfer_stash(pid, session_id, url, ws, continuation) do
    case GenServer.call(pid, {:prepare_stash, ws}) do
      {:ok, ref} -> transfer_reserved(pid, ref, session_id, url, ws, continuation)
    end
  end

  defp transfer_reserved(pid, ref, session_id, url, ws, continuation) do
    case transfer_connection(ws, pid) do
      {:ok, transferred_ws} ->
        GenServer.call(
          pid,
          {:commit_stash, ref, session_id, url, transferred_ws, continuation}
        )

      {:error, _reason} ->
        GenServer.call(pid, {:abort_stash, ref})
    end
  end

  defp transfer_connection(ws, pid) do
    case Mint.HTTP.controlling_process(ws.conn, pid) do
      {:ok, mint_conn} -> {:ok, %{ws | conn: mint_conn}}
      {:error, reason} -> {:error, reason}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp store_entry(state, session_id, url, ws, continuation) do
    state = evict_expired(state)
    close_replaced(state, state.entries[session_id])

    entry = %{
      url: url,
      conn: ws,
      continuation: continuation,
      idle_at: now(state),
      sequence: state.sequence
    }

    state = %{
      state
      | entries: Map.put(state.entries, session_id, entry),
        sequence: state.sequence + 1
    }

    state |> enforce_max_entries() |> reschedule_expiry()
  end

  defp close_pending(state, monitor) do
    case Enum.find(state.pending, fn {_ref, entry} -> entry.monitor == monitor end) do
      nil ->
        state

      {ref, entry} ->
        close_entry(state, entry)
        %{state | pending: Map.delete(state.pending, ref)}
    end
  end

  defp close_all_pending(state) do
    Enum.each(state.pending, fn {_ref, entry} -> close_entry(state, entry) end)
    :ok
  end

  defp route_socket_message(state, msg) do
    Enum.reduce_while(state.entries, state, fn {session_id, entry}, st ->
      case WebSocket.handle_idle(entry.conn, msg) do
        :unknown ->
          {:cont, st}

        {:ok, ws} ->
          {:halt, %{st | entries: Map.put(st.entries, session_id, %{entry | conn: ws})}}

        {:closed, reason} ->
          Logger.debug("[conn_cache] idle codex ws for #{session_id} closed: #{inspect(reason)}")
          close_entry(st, entry)
          {:halt, %{st | entries: Map.delete(st.entries, session_id)}}
      end
    end)
  end

  defp enforce_max_entries(state) do
    overflow = map_size(state.entries) - state.max_entries

    state.entries
    |> Enum.sort_by(&eviction_key/1)
    |> Enum.take(max(overflow, 0))
    |> Enum.reduce(state, fn {session_id, entry}, state ->
      close_entry(state, entry)
      %{state | entries: Map.delete(state.entries, session_id)}
    end)
  end

  defp evict_expired(state) do
    state.entries
    |> Enum.filter(fn {_session_id, entry} -> expired?(state, entry) end)
    |> Enum.sort_by(&eviction_key/1)
    |> Enum.reduce(state, fn {session_id, entry}, state ->
      close_entry(state, entry)
      %{state | entries: Map.delete(state.entries, session_id)}
    end)
  end

  defp expired?(state, entry), do: now(state) - entry.idle_at >= state.idle_ttl_ms

  defp eviction_key({session_id, entry}),
    do: {entry.idle_at, entry.sequence, session_id}

  defp close_replaced(_state, nil), do: :ok
  defp close_replaced(state, entry), do: close_entry(state, entry)

  defp close_entry(state, entry) do
    state.close.(entry.conn)
  rescue
    exception ->
      Logger.debug("[conn_cache] failed to close idle codex ws: #{Exception.message(exception)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("[conn_cache] failed to close idle codex ws: #{inspect(reason)}")
      :ok
  end

  defp reschedule_expiry(state) do
    state = cancel_expiry(state)

    case next_expiry(state) do
      :none ->
        state

      deadline ->
        token = make_ref()
        timer = Process.send_after(self(), {:expire_idle, token}, max(deadline - now(state), 0))
        %{state | expiry_timer: {timer, token}}
    end
  end

  defp cancel_expiry(%{expiry_timer: nil} = state), do: state

  defp cancel_expiry(%{expiry_timer: {timer, _token}} = state) do
    Process.cancel_timer(timer, async: true, info: false)
    %{state | expiry_timer: nil}
  end

  defp next_expiry(%{entries: entries}) when map_size(entries) == 0, do: :none

  defp next_expiry(state) do
    state.entries
    |> Map.values()
    |> Enum.map(&(&1.idle_at + state.idle_ttl_ms))
    |> Enum.min()
  end

  defp validate_idle_ttl(value) when is_integer(value) and value > 0, do: :ok
  defp validate_idle_ttl(value), do: {:error, {:invalid_idle_ttl_ms, value}}

  defp validate_max_entries(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_max_entries(value), do: {:error, {:invalid_max_entries, value}}

  defp now(state), do: state.clock.()
end
