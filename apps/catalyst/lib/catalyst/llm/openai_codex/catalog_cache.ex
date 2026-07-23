defmodule Catalyst.LLM.OpenAICodex.CatalogCache do
  @moduledoc """
  Supervised cache for the live OpenAI Codex model catalog.

  Reads return immediately with the current entries and trigger a background
  refresh when stale. The cache owns exactly one refresh task at a time;
  explicit refresh callers join that task. Runtime freshness uses monotonic
  time, and `x-models-etag` observations enter through `notice_etag/2` casts.

  Setting `config :catalyst, :codex_live_models, false` disables automatic
  refreshes and ETag handling. It deliberately does not discard entries that
  were already cached, and `refresh/1` remains an explicit fetch operation.
  """

  use GenServer

  alias Catalyst.Tasks
  alias Catalyst.Auth.TokenStore
  alias Catalyst.LLM.OpenAICodex.{Catalog, CatalogCache.State}

  @base_url "https://chatgpt.com/backend-api"
  @models_client_version "0.142.5"
  @ttl_ms 300_000
  @retry_ms 30_000
  @refresh_timeout_ms 40_000
  @call_timeout 45_000

  @type server :: GenServer.server()
  @type fetch_result :: {:ok, [Catalog.entry()], String.t() | nil} | {:error, term()}

  @doc "Start the catalog cache."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Return cached entries immediately, scheduling a single background refresh
  when the cache is stale and live catalogs are enabled.

  An unavailable cache is treated as empty so callers can use the bundled
  fallback during startup, shutdown, and in bare scripts.
  """
  @spec models(server()) :: [Catalog.entry()]
  def models(server \\ __MODULE__) do
    GenServer.call(server, :models)
  catch
    :exit, _reason -> []
  end

  @doc """
  Fetch the live catalog now and cache it.

  Concurrent callers and automatic triggers share one in-flight fetch.
  Returns `{:ok, entries}` or `{:error, reason}`.
  """
  @spec refresh(server()) :: {:ok, [Catalog.entry()]} | {:error, term()}
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh, @call_timeout)
  catch
    :exit, reason -> {:error, {:cache_unavailable, reason}}
  end

  @doc """
  Notice an `x-models-etag` value without blocking the response path.

  A matching value renews the TTL; a changed value schedules a refresh.
  """
  @spec notice_etag(String.t() | nil, server()) :: :ok
  def notice_etag(etag, server \\ __MODULE__)
  def notice_etag(nil, _server), do: :ok
  def notice_etag(etag, server) when is_binary(etag), do: GenServer.cast(server, {:etag, etag})

  @doc """
  Fetch and parse `GET <base>/codex/models?client_version=...`.

  The response ETag is returned for later comparison with response headers.
  """
  @spec fetch_live_models(String.t(), String.t(), String.t()) :: fetch_result()
  def fetch_live_models(token, account_id, base_url) do
    url = String.replace_trailing(base_url, "/", "") <> "/codex/models"

    headers = [
      {"authorization", "Bearer #{token}"},
      {"chatgpt-account-id", account_id},
      {"originator", "codex_cli_rs"},
      {"version", @models_client_version},
      {"accept", "application/json"}
    ]

    case Req.get(url,
           params: [client_version: @models_client_version],
           headers: headers,
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"models" => models}} = response} when is_list(models) ->
        etag = response.headers |> Map.get("etag", []) |> List.first()
        {:ok, Catalog.parse_live_models(models), etag}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  @doc false
  @spec store([Catalog.entry()], keyword()) :: :ok
  def store(entries, opts \\ []) when is_list(entries) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:store, entries, Keyword.get(opts, :etag)})
  end

  # test seam: clears all cached catalog state between tests.
  @doc false
  @spec reset(server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(opts) do
    {:ok,
     %State{
       fetcher: Keyword.get(opts, :fetcher, &fetch_authenticated/0),
       clock: Keyword.get(opts, :clock, &Tasks.monotonic_ms/0),
       enabled?: Keyword.get(opts, :enabled?, &live_enabled?/0),
       ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms),
       retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
       refresh_timeout_ms: Keyword.get(opts, :refresh_timeout_ms, @refresh_timeout_ms),
       task_supervisor: Keyword.get(opts, :task_supervisor, Catalyst.TaskSupervisor)
     }}
  end

  @impl true
  def handle_call(:models, _from, state) do
    {:reply, state.entries, maybe_refresh(state)}
  end

  def handle_call(:refresh, from, %State{refresh: %Task{}} = state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:refresh, from, state) do
    case start_refresh(%{state | waiters: [from | state.waiters]}) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:reply, {:error, reason}, %{state | waiters: []}}
    end
  end

  def handle_call({:store, entries, etag}, _from, state) do
    {:reply, :ok,
     %{
       state
       | entries: entries,
         etag: etag,
         fresh_at: now(state),
         last_attempt_at: nil
     }}
  end

  def handle_call(:reset, _from, %State{refresh: nil} = state) do
    {:reply, :ok, cleared(state)}
  end

  def handle_call(:reset, _from, state) do
    state = cancel_refresh_timer(state)
    _ = Task.shutdown(state.refresh, :brutal_kill)
    reply_waiters(state.waiters, {:error, :reset})
    {:reply, :ok, cleared(state)}
  end

  @impl true
  def handle_cast({:etag, etag}, state) do
    {:noreply, handle_etag(state, etag)}
  end

  @impl true
  def handle_info({ref, result}, %State{refresh: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> cancel_refresh_timer() |> finish_refresh(result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{refresh: %Task{ref: ref}} = state
      ) do
    result = {:error, {:refresh_exit, reason}}
    reply_waiters(state.waiters, result)
    state = cancel_refresh_timer(state)
    {:noreply, %{state | refresh: nil, waiters: []}}
  end

  def handle_info(
        {:refresh_timeout, ref},
        %State{refresh: %Task{ref: ref}} = state
      ) do
    state = cancel_refresh_timer(state)

    # A completed Task reply may already be queued behind the timer. Salvage
    # it before declaring a timeout so a successful catalog is not discarded.
    case Task.shutdown(state.refresh, :brutal_kill) do
      {:ok, result} ->
        {:noreply, finish_refresh(state, result)}

      _not_completed ->
        result = {:error, :timeout}
        reply_waiters(state.waiters, result)
        {:noreply, %{state | refresh: nil, waiters: []}}
    end
  end

  def handle_info({:refresh_timeout, _stale_ref}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp maybe_refresh(state) do
    case state.enabled?.() and stale?(state) and retry_ready?(state) do
      true -> start_refresh_best_effort(state)
      false -> state
    end
  end

  defp handle_etag(state, etag) do
    cond do
      not state.enabled?.() -> state
      state.etag == etag -> %{state | fresh_at: now(state)}
      retry_ready?(state) -> start_refresh_best_effort(state)
      true -> state
    end
  end

  defp start_refresh_best_effort(%State{refresh: %Task{}} = state), do: state

  defp start_refresh_best_effort(state) do
    case start_refresh(state) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  defp start_refresh(state) do
    task = Tasks.async_on(state.task_supervisor, state.fetcher)
    timer = Process.send_after(self(), {:refresh_timeout, task.ref}, state.refresh_timeout_ms)
    attempted_at = now(state)
    {:ok, %{state | refresh: task, refresh_timer: timer, last_attempt_at: attempted_at}}
  catch
    :exit, reason -> {:error, {:task_start_failed, reason}, state}
  end

  defp finish_refresh(state, {:ok, entries, etag}) when is_list(entries) do
    result = {:ok, entries}
    reply_waiters(state.waiters, result)

    %{
      state
      | entries: entries,
        etag: etag,
        fresh_at: now(state),
        refresh: nil,
        refresh_timer: nil,
        waiters: []
    }
  end

  defp finish_refresh(state, {:error, reason}) do
    result = {:error, reason}
    reply_waiters(state.waiters, result)
    %{state | refresh: nil, waiters: []}
  end

  defp finish_refresh(state, other) do
    finish_refresh(state, {:error, {:invalid_refresh_result, other}})
  end

  defp fetch_authenticated do
    case TokenStore.get_access_token("openai-codex") do
      {:ok, %{access: token, account_id: account_id}} when is_binary(account_id) ->
        fetch_live_models(token, account_id, @base_url)

      _not_authenticated ->
        {:error, :not_authenticated}
    end
  end

  defp stale?(%State{fresh_at: nil}), do: true
  defp stale?(state), do: now(state) - state.fresh_at > state.ttl_ms

  defp retry_ready?(%State{refresh: %Task{}}), do: false
  defp retry_ready?(%State{last_attempt_at: nil}), do: true
  defp retry_ready?(state), do: now(state) - state.last_attempt_at > state.retry_ms

  defp cleared(state) do
    %{
      state
      | entries: [],
        etag: nil,
        fresh_at: nil,
        last_attempt_at: nil,
        refresh: nil,
        refresh_timer: nil,
        waiters: []
    }
  end

  defp reply_waiters(waiters, result) do
    Enum.each(waiters, &GenServer.reply(&1, result))
  end

  defp cancel_refresh_timer(%State{refresh_timer: nil} = state), do: state

  defp cancel_refresh_timer(%State{refresh_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | refresh_timer: nil}
  end

  defp now(state), do: state.clock.()
  defp live_enabled?, do: Application.get_env(:catalyst, :codex_live_models, true)
end
