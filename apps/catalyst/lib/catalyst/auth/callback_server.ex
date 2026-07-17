defmodule Catalyst.Auth.CallbackServer do
  @moduledoc """
  Transient localhost HTTP server for the OAuth redirect. Bound to
  `127.0.0.1:1455` (the fixed Codex redirect URI), it serves a single
  `/auth/callback` route, validates `state`, captures `code`, and hands it to the
  waiting login process, then shuts down. Requests without the expected `state`
  get a 400 and the server keeps waiting, so a drive-by request can't abort a
  pending sign-in.
  """

  alias Catalyst.Auth.OpenAIOAuth

  @current_key {__MODULE__, :current}

  defstruct [:server, :parent]

  @type t :: %__MODULE__{server: pid(), parent: pid()}

  @doc """
  Bind the callback listener and return only after Bandit has started it.

  An abandoned earlier sign-in (browser tab closed, user retried) is
  SUPERSEDED, not waited out: its server is stopped so the fixed port frees
  immediately, and its waiting process gets `{:error, :superseded}` — a second
  login attempt within the 5-minute window used to fail with address-in-use.
  """
  @spec start(String.t()) :: {:ok, t()} | {:error, term()}
  def start(expected_state) do
    supersede_previous()
    parent = self()
    plug = {__MODULE__.Handler, %{parent: parent, state: expected_state}}

    case Bandit.start_link(
           plug: plug,
           scheme: :http,
           port: OpenAIOAuth.callback_port(),
           thousand_island_options: [transport_options: [ip: {127, 0, 0, 1}]],
           startup_log: false
         ) do
      {:ok, server} ->
        :persistent_term.put(@current_key, {server, parent})
        {:ok, %__MODULE__{server: server, parent: parent}}

      {:error, reason} ->
        {:error, {:callback_server, reason}}
    end
  end

  @doc """
  Wait for the redirect on a listener returned by `start/1`, then stop it.

  Must be called by the same process that called `start/1`. Returns
  `{:ok, code}` or `{:error, reason}`.
  """
  @spec await(t(), timeout()) :: {:ok, String.t()} | {:error, term()}
  def await(callback, timeout \\ 300_000)

  def await(%__MODULE__{server: server, parent: parent}, timeout) when parent == self() do
    result =
      receive do
        {:oauth_code, code} -> {:ok, code}
        {:oauth_error, reason} -> {:error, reason}
      after
        timeout -> {:error, :timeout}
      end

    release(server)
    result
  end

  defp supersede_previous do
    case :persistent_term.get(@current_key, nil) do
      {server, parent} when is_pid(server) ->
        if Process.alive?(parent), do: send(parent, {:oauth_error, :superseded})
        stop(server)
        :persistent_term.erase(@current_key)

      _none ->
        :ok
    end
  end

  defp release(server) do
    case :persistent_term.get(@current_key, nil) do
      {^server, _parent} -> :persistent_term.erase(@current_key)
      _superseded_or_none -> :ok
    end

    stop(server)
  end

  defp stop(server) do
    try do
      Supervisor.stop(server, :normal, 5_000)
    catch
      _, _ -> Process.exit(server, :kill)
    end
  end
end
