defmodule Catalyst.Auth.TokenStore do
  @moduledoc """
  Holds OAuth credentials and serves fresh access tokens.

  Backed by `~/.catalyst/auth.json` (0600). `get_access_token/1` refreshes
  single-flight per provider: the refresh runs in a supervised Task while the
  server keeps serving other calls; every caller that arrives during the
  refresh is queued and replied to when it completes.
  """

  use GenServer
  require Logger

  alias Catalyst.Tasks
  alias Catalyst.Auth.{Flow, OpenAIOAuth}
  alias Catalyst.Files.AtomicWrite

  @skew_ms 60_000
  @refresh_timeout_ms 30_000

  @typedoc "What `get_access_token/1` serves to callers."
  @type token :: %{access: String.t(), account_id: String.t() | nil}

  # ---- API ------------------------------------------------------------------

  @doc "Start the (singleton, named) token store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "A fresh `{:ok, %{access, account_id}}` for a provider, refreshing if needed."
  @spec get_access_token(String.t()) :: {:ok, token()} | {:error, term()}
  def get_access_token(provider \\ OpenAIOAuth.provider_id()),
    do: GenServer.call(__MODULE__, {:get, provider}, 60_000)

  @doc """
  Store credentials (string- or atom-keyed) for a provider and persist.

  Supersedes any in-flight refresh for the same provider: its waiters are
  replied to with these credentials and its result is discarded.
  """
  @spec put(String.t(), map()) :: :ok | {:error, term()}
  def put(provider, creds), do: GenServer.call(__MODULE__, {:put, provider, normalize(creds)})

  @doc "Whether a provider has stored credentials."
  @spec logged_in?(String.t()) :: boolean()
  def logged_in?(provider \\ OpenAIOAuth.provider_id()),
    do: GenServer.call(__MODULE__, {:logged_in?, provider})

  @doc "Forget a provider's credentials and persist."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(provider), do: GenServer.call(__MODULE__, {:delete, provider})

  @doc """
  Mark a provider's cached access token as expired (in memory only) so the next
  `get_access_token/1` forces a refresh through the usual single-flight path.
  No-op when the provider has no stored credentials.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(provider), do: GenServer.call(__MODULE__, {:invalidate, provider})

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{creds: load(), refreshing: %{}}}

  # If this server ever crashes, OTP's crash report logs the state and the last
  # message — both can carry access/refresh tokens. Redact them.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, %{creds: creds} = state} ->
        {:state, %{state | creds: Map.new(creds, fn {provider, _} -> {provider, :redacted} end)}}

      {:message, {:put, provider, creds}} when is_map(creds) ->
        {:message, {:put, provider, :redacted}}

      other ->
        other
    end)
  end

  @impl true
  def handle_call({:get, provider}, from, state) do
    case Map.get(state.creds, provider) do
      nil ->
        {:reply, {:error, :not_logged_in}, state}

      creds ->
        case fresh?(creds) do
          true -> {:reply, {:ok, public(creds)}, state}
          false -> {:noreply, start_or_join_refresh(provider, creds, from, state)}
        end
    end
  end

  def handle_call({:put, provider, creds}, _from, state) do
    new_creds = Map.put(state.creds, provider, creds)

    case persist(new_creds) do
      :ok ->
        state = supersede_refresh(state, provider, creds)
        {:reply, :ok, %{state | creds: new_creds}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:logged_in?, provider}, _from, state),
    do: {:reply, Map.has_key?(state.creds, provider), state}

  def handle_call({:delete, provider}, _from, state) do
    new_creds = Map.delete(state.creds, provider)

    case persist(new_creds) do
      :ok ->
        state = cancel_refresh(state, provider, :not_logged_in)
        {:reply, :ok, %{state | creds: new_creds}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:invalidate, provider}, _from, state) do
    case Map.get(state.creds, provider) do
      nil ->
        {:reply, :ok, state}

      creds ->
        # In-memory only: freshness is a cache hint, and the refresh that this
        # forces will persist the real new expiry.
        stale = Map.put(creds, "expires", 0)
        {:reply, :ok, %{state | creds: Map.put(state.creds, provider, stale)}}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case pop_refresh(state, ref) do
      :error ->
        {:noreply, state}

      {:ok, provider, inflight, state} ->
        finish_refresh(inflight)
        {:noreply, apply_refresh(provider, result, inflight.waiters, state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case pop_refresh(state, ref) do
      :error ->
        {:noreply, state}

      {:ok, _provider, inflight, state} ->
        cancel_timer(inflight)

        Enum.each(
          inflight.waiters,
          &GenServer.reply(&1, {:error, {:refresh_failed, reason}})
        )

        {:noreply, state}
    end
  end

  def handle_info({:refresh_timeout, provider, ref}, state) do
    case state.refreshing[provider] do
      %{task: %Task{ref: ^ref}} = inflight ->
        state = %{state | refreshing: Map.delete(state.refreshing, provider)}

        # The timer can be dequeued just before an already-completed Task
        # reply. Task.shutdown/2 checks the mailbox, so preserve that result
        # instead of throwing away rotated credentials at the boundary.
        case stop_refresh(inflight) do
          {:ok, result} ->
            {:noreply, apply_refresh(provider, result, inflight.waiters, state)}

          _not_completed ->
            Enum.each(
              inflight.waiters,
              &GenServer.reply(&1, {:error, {:refresh_failed, :timeout}})
            )

            {:noreply, state}
        end

      _missing_or_superseded ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- internals ------------------------------------------------------------

  # Single-flight: the first stale caller starts a refresh Task; later callers
  # just join its waiter list. The server is never blocked on the HTTP call.
  defp start_or_join_refresh(provider, creds, from, state) do
    case state.refreshing[provider] do
      %{waiters: waiters} = inflight ->
        put_in(state.refreshing[provider], %{inflight | waiters: [from | waiters]})

      nil ->
        task = Tasks.async(fn -> refresh(provider, creds) end)

        timer =
          Process.send_after(
            self(),
            {:refresh_timeout, provider, task.ref},
            refresh_timeout()
          )

        put_in(state.refreshing[provider], %{task: task, timer: timer, waiters: [from]})
    end
  end

  # The legacy global override remains the first choice so extensions and tests
  # keep their existing contract. Built-in providers otherwise dispatch to the
  # OAuth flow that issued their stored credentials.
  defp refresh(provider, creds) do
    case Application.get_env(:catalyst, :oauth_refresh_fun) do
      fun when is_function(fun, 1) -> fun.(creds["refresh"])
      nil -> refresh_provider(provider, creds)
    end
  end

  defp refresh_provider(provider, creds) do
    with {:ok, flow} <- Flow.resolve(provider) do
      flow.refresh(creds)
    end
  end

  # A fresh login (`put/2`) during an in-flight refresh supersedes it: waiters
  # get the new credentials now, and dropping the entry makes `pop_refresh/2`
  # miss when the Task completes, so its result is discarded. Otherwise the
  # refresh result would clobber the fresh login — with refresh-token rotation
  # that can persist dead credentials.
  defp supersede_refresh(state, provider, creds) do
    case Map.pop(state.refreshing, provider) do
      {nil, _refreshing} ->
        state

      {%{waiters: waiters} = inflight, refreshing} ->
        stop_refresh(inflight)
        Enum.each(waiters, &GenServer.reply(&1, {:ok, public(creds)}))
        %{state | refreshing: refreshing}
    end
  end

  # Sign-out supersedes an in-flight refresh just like a fresh login does. Drop
  # the entry so the task result is discarded when it arrives, and release any
  # callers already waiting for the refresh instead of letting logout hang them.
  defp cancel_refresh(state, provider, reason) do
    case Map.pop(state.refreshing, provider) do
      {nil, _refreshing} ->
        state

      {%{waiters: waiters} = inflight, refreshing} ->
        stop_refresh(inflight)
        Enum.each(waiters, &GenServer.reply(&1, {:error, reason}))
        %{state | refreshing: refreshing}
    end
  end

  defp pop_refresh(state, ref) do
    case Enum.find(state.refreshing, fn {_provider, %{task: task}} -> task.ref == ref end) do
      nil ->
        :error

      {provider, inflight} ->
        {:ok, provider, inflight, %{state | refreshing: Map.delete(state.refreshing, provider)}}
    end
  end

  defp finish_refresh(%{task: task} = inflight) do
    cancel_timer(inflight)
    Process.demonitor(task.ref, [:flush])
    :ok
  end

  defp stop_refresh(%{task: task} = inflight) do
    cancel_timer(inflight)
    Task.shutdown(task, :brutal_kill)
  end

  defp cancel_timer(%{timer: timer}) do
    Process.cancel_timer(timer)
    :ok
  end

  defp refresh_timeout,
    do: Application.get_env(:catalyst, :oauth_refresh_timeout, @refresh_timeout_ms)

  defp apply_refresh(provider, {:ok, new_creds}, waiters, state) do
    # Keep the stored account id when the refreshed token lacks the claim
    # (credentials_from always sets the key, possibly to nil).
    new_creds =
      case new_creds["account_id"] do
        account_id when is_binary(account_id) ->
          new_creds

        _missing ->
          old = Map.get(state.creds, provider) || %{}
          Map.put(new_creds, "account_id", old["account_id"])
      end

    creds = Map.put(state.creds, provider, new_creds)

    case persist(creds) do
      :ok ->
        Enum.each(waiters, &GenServer.reply(&1, {:ok, public(new_creds)}))
        %{state | creds: creds}

      {:error, reason} ->
        Enum.each(waiters, &GenServer.reply(&1, {:error, {:refresh_failed, reason}}))
        state
    end
  end

  defp apply_refresh(_provider, {:error, reason}, waiters, state) do
    Enum.each(waiters, &GenServer.reply(&1, {:error, {:refresh_failed, reason}}))
    state
  end

  defp fresh?(%{"expires" => expires}) when is_integer(expires),
    do: expires - System.system_time(:millisecond) > @skew_ms

  defp fresh?(_), do: false

  defp public(creds), do: %{access: creds["access"], account_id: creds["account_id"]}

  defp normalize(creds) do
    Map.new(creds, fn {k, v} -> {to_string(k), v} end)
  end

  defp load do
    case File.read(auth_path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = map} -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  # Never raises: a disk error here (full disk, read-only home) inside a
  # handle_call would crash the server — and the resulting crash report would
  # carry token material (see format_status/1, which only mitigates). Callers
  # receive the tagged error and memory remains unchanged, so :ok means durable.
  defp persist(creds) do
    path = auth_path()
    dir = Path.dirname(path)

    result =
      with {:ok, json} <- Jason.encode(creds),
           :ok <- File.mkdir_p(dir),
           _ = File.chmod(dir, 0o700),
           # AtomicWrite applies the mode to the empty temp file before token
           # bytes are written, syncs it, then renames it into place.
           :ok <- AtomicWrite.write(path, json, mode: 0o600) do
        :ok
      end

    with {:error, reason} <- result do
      Logger.warning("[auth] could not persist credentials to #{path}: #{inspect(reason)}")

      {:error, reason}
    end
  end

  defp auth_path do
    Application.get_env(:catalyst, :auth_path) || Catalyst.Paths.auth()
  end
end
