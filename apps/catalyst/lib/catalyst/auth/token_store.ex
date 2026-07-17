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

  alias Catalyst.Auth.OpenAIOAuth

  @skew_ms 60_000

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
  @spec put(String.t(), map()) :: :ok
  def put(provider, creds), do: GenServer.call(__MODULE__, {:put, provider, normalize(creds)})

  @doc "Whether a provider has stored credentials."
  @spec logged_in?(String.t()) :: boolean()
  def logged_in?(provider \\ OpenAIOAuth.provider_id()),
    do: GenServer.call(__MODULE__, {:logged_in?, provider})

  @doc "Forget a provider's credentials and persist."
  @spec delete(String.t()) :: :ok
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
        if fresh?(creds) do
          {:reply, {:ok, public(creds)}, state}
        else
          {:noreply, start_or_join_refresh(provider, creds, from, state)}
        end
    end
  end

  def handle_call({:put, provider, creds}, _from, state) do
    state = supersede_refresh(state, provider, creds)
    state = %{state | creds: Map.put(state.creds, provider, creds)}
    persist(state.creds)
    {:reply, :ok, state}
  end

  def handle_call({:logged_in?, provider}, _from, state),
    do: {:reply, Map.has_key?(state.creds, provider), state}

  def handle_call({:delete, provider}, _from, state) do
    state = cancel_refresh(state, provider, :not_logged_in)
    state = %{state | creds: Map.delete(state.creds, provider)}
    persist(state.creds)
    {:reply, :ok, state}
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
      nil ->
        {:noreply, state}

      {provider, waiters, state} ->
        Process.demonitor(ref, [:flush])
        {:noreply, apply_refresh(provider, result, waiters, state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case pop_refresh(state, ref) do
      nil ->
        {:noreply, state}

      {_provider, waiters, state} ->
        Enum.each(waiters, &GenServer.reply(&1, {:error, {:refresh_failed, reason}}))
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
        refresh = refresh_fun()

        task =
          Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fn ->
            refresh.(creds["refresh"])
          end)

        put_in(state.refreshing[provider], %{ref: task.ref, waiters: [from]})
    end
  end

  # Injectable for tests; defaults to the real OAuth refresh.
  defp refresh_fun,
    do: Application.get_env(:catalyst, :oauth_refresh_fun, &OpenAIOAuth.refresh/1)

  # A fresh login (`put/2`) during an in-flight refresh supersedes it: waiters
  # get the new credentials now, and dropping the entry makes `pop_refresh/2`
  # miss when the Task completes, so its result is discarded. Otherwise the
  # refresh result would clobber the fresh login — with refresh-token rotation
  # that can persist dead credentials.
  defp supersede_refresh(state, provider, creds) do
    case Map.pop(state.refreshing, provider) do
      {nil, _refreshing} ->
        state

      {%{waiters: waiters}, refreshing} ->
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

      {%{waiters: waiters}, refreshing} ->
        Enum.each(waiters, &GenServer.reply(&1, {:error, reason}))
        %{state | refreshing: refreshing}
    end
  end

  defp pop_refresh(state, ref) do
    case Enum.find(state.refreshing, fn {_p, %{ref: r}} -> r == ref end) do
      nil ->
        nil

      {provider, %{waiters: waiters}} ->
        {provider, waiters, %{state | refreshing: Map.delete(state.refreshing, provider)}}
    end
  end

  defp apply_refresh(provider, {:ok, new_creds}, waiters, state) do
    # Keep the stored account id when the refreshed token lacks the claim
    # (credentials_from always sets the key, possibly to nil).
    new_creds =
      if new_creds["account_id"] do
        new_creds
      else
        old = Map.get(state.creds, provider) || %{}
        Map.put(new_creds, "account_id", old["account_id"])
      end

    creds = Map.put(state.creds, provider, new_creds)
    persist(creds)
    Enum.each(waiters, &GenServer.reply(&1, {:ok, public(new_creds)}))
    %{state | creds: creds}
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
  # carry token material (see format_status/1, which only mitigates). The creds
  # stay usable in memory; losing persistence costs a re-login after restart.
  defp persist(creds) do
    path = auth_path()
    dir = Path.dirname(path)
    tmp = path <> ".tmp"

    result =
      with {:ok, json} <- Jason.encode(creds),
           :ok <- File.mkdir_p(dir),
           _ = File.chmod(dir, 0o700),
           # Restrict the temp file BEFORE writing token material into it, then
           # atomically swap it in (rename preserves the mode).
           :ok <- File.touch(tmp),
           :ok <- File.chmod(tmp, 0o600),
           :ok <- File.write(tmp, json) do
        File.rename(tmp, path)
      end

    with {:error, reason} <- result do
      Logger.warning(
        "[auth] could not persist credentials to #{path}: #{inspect(reason)} — " <>
          "tokens stay in memory; you will need to sign in again after a restart"
      )

      {:error, reason}
    end
  end

  defp auth_path do
    Application.get_env(:catalyst, :auth_path) || Path.expand("~/.catalyst/auth.json")
  end
end
