defmodule Catalyst.Auth.TokenStore do
  @moduledoc """
  Holds OAuth credentials and serves fresh access tokens.

  Backed by `~/.catalyst/auth.json` (0600). `get_access_token/1` refreshes
  single-flight when a token is within `@skew` of expiry — because it runs inside
  the GenServer, concurrent callers serialize behind one refresh.
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

  # ---- callbacks ------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, load()}

  @impl true
  def handle_call({:get, provider}, _from, state) do
    case Map.get(state, provider) do
      nil ->
        {:reply, {:error, :not_logged_in}, state}

      creds ->
        if fresh?(creds) do
          {:reply, {:ok, public(creds)}, state}
        else
          refresh(provider, creds, state)
        end
    end
  end

  def handle_call({:put, provider, creds}, _from, state) do
    state = Map.put(state, provider, creds)
    persist(state)
    {:reply, :ok, state}
  end

  def handle_call({:logged_in?, provider}, _from, state),
    do: {:reply, Map.has_key?(state, provider), state}

  # ---- internals ------------------------------------------------------------

  defp refresh(provider, creds, state) do
    case OpenAIOAuth.refresh(creds["refresh"]) do
      {:ok, new_creds} ->
        new_creds = Map.put_new(new_creds, "account_id", creds["account_id"])
        state = Map.put(state, provider, new_creds)
        persist(state)
        {:reply, {:ok, public(new_creds)}, state}

      {:error, reason} ->
        {:reply, {:error, {:refresh_failed, reason}}, state}
    end
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

  defp persist(state) do
    path = auth_path()
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(state))
    File.rename!(tmp, path)
    _ = File.chmod(path, 0o600)
    :ok
  end

  defp auth_path do
    Application.get_env(:catalyst, :auth_path) || Path.expand("~/.catalyst/auth.json")
  end
end
