defmodule Catalyst.Auth.TokenStore do
  @moduledoc """
  Holds OAuth credentials and serves fresh access tokens.

  Backed by `~/.catalyst/auth.json` (0600). `get_access_token/1` refreshes
  single-flight per provider: the refresh runs in a supervised Task while the
  server keeps serving other calls; every caller that arrives during the
  refresh is queued and replied to when it completes.
  """

  use GenServer

  alias Catalyst.Auth.OpenAIOAuth

  @skew_ms 60_000

  # ---- API ------------------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "A fresh `{:ok, %{access, account_id}}` for a provider, refreshing if needed."
  def get_access_token(provider \\ "openai-codex"),
    do: GenServer.call(__MODULE__, {:get, provider}, 60_000)

  @doc "Store credentials (string- or atom-keyed) for a provider and persist."
  def put(provider, creds), do: GenServer.call(__MODULE__, {:put, provider, normalize(creds)})

  @doc "Whether a provider has stored credentials."
  def logged_in?(provider \\ "openai-codex"),
    do: GenServer.call(__MODULE__, {:logged_in?, provider})

  @doc "Forget a provider's credentials and persist."
  def delete(provider), do: GenServer.call(__MODULE__, {:delete, provider})

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{creds: load(), refreshing: %{}}}

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
    state = %{state | creds: Map.put(state.creds, provider, creds)}
    persist(state.creds)
    {:reply, :ok, state}
  end

  def handle_call({:logged_in?, provider}, _from, state),
    do: {:reply, Map.has_key?(state.creds, provider), state}

  def handle_call({:delete, provider}, _from, state) do
    state = %{state | creds: Map.delete(state.creds, provider)}
    persist(state.creds)
    {:reply, :ok, state}
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

  defp persist(creds) do
    path = auth_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    _ = File.chmod(dir, 0o700)

    # Restrict the temp file BEFORE writing token material into it, then
    # atomically swap it in (rename preserves the mode).
    tmp = path <> ".tmp"
    File.touch!(tmp)
    File.chmod!(tmp, 0o600)
    File.write!(tmp, Jason.encode!(creds))
    File.rename!(tmp, path)
    :ok
  end

  defp auth_path do
    Application.get_env(:catalyst, :auth_path) || Path.expand("~/.catalyst/auth.json")
  end
end
