defmodule CatalystWeb.ShellLive.SessionLifecycle do
  @moduledoc """
  Attaches, starts, monitors, and replaces the session owned by the shell UI.

  Sessions deliberately outlive LiveViews. The most recent session id is stored
  under the historical `ShellLive` key so reconnects and UI reloads can rebuild
  their transient projection from the server snapshot.
  """

  require Logger

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Catalyst.Session.{Manager, Server}
  alias CatalystWeb.ShellLive.{ChatInput, Conversation, Settings}

  @session_ptr {CatalystWeb.ShellLive, :current_session}
  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Returns the initial working directory for development or a packaged release."
  @spec default_cwd() :: String.t()
  def default_cwd do
    case System.get_env("RELEASE_NAME") do
      nil -> File.cwd!()
      _release -> System.user_home!()
    end
  end

  @doc "Reattaches to the remembered live session or starts a replacement."
  @spec attach_or_start(socket()) :: socket()
  def attach_or_start(socket) do
    case remembered_session() do
      %{id: id} -> attach_remembered(socket, id)
      _none -> start(socket)
    end
  end

  @doc "Starts a new session, replacing the one currently attached to the shell."
  @spec start(socket()) :: socket()
  def start(socket) do
    stop_attached_session(socket)

    {provider, model} = Settings.provider_config(socket.assigns.codex_prefs)
    run_opts = Settings.run_opts(socket.assigns.codex_prefs)

    case Manager.start_session(
           cwd: socket.assigns.cwd,
           provider: provider,
           model: model,
           opts: run_opts
         ) do
      {:ok, %{id: id, pid: pid}} ->
        attach_new_session(socket, id, pid, model, run_opts)

      {:error, reason} ->
        session_start_failed(socket, reason)
    end
  end

  @doc "Changes the working directory and replaces the session at that location."
  @spec change_cwd(socket(), String.t()) :: socket()
  def change_cwd(socket, path) do
    expanded = Path.expand(path, socket.assigns.cwd)

    case File.dir?(expanded) do
      true ->
        socket
        |> assign(cwd: expanded)
        |> ChatInput.put_text("")
        |> start()

      false ->
        put_flash(socket, :error, "Not a directory: #{expanded}")
    end
  end

  defp attach_remembered(socket, id) do
    case await_session(id) do
      {:ok, pid} ->
        reattach(socket, id, pid)

      :error ->
        # A crashed child can re-register under the abandoned id after this
        # lookup. Stop it before moving the UI to a new session.
        Manager.stop(id)
        start(socket)
    end
  end

  defp await_session(id, retries \\ 5)
  defp await_session(id, 0), do: Manager.whereis(id)

  defp await_session(id, retries) do
    case Manager.whereis(id) do
      :error ->
        Process.sleep(20)
        await_session(id, retries - 1)

      {:ok, _pid} = found ->
        found
    end
  end

  defp reattach(socket, id, pid) do
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    socket
    |> monitor(pid)
    |> assign(session_id: id, session_pid: pid)
    |> Conversation.replay(pid)
    |> Settings.sync_from_session()
  catch
    # Only a dead GenServer is recoverable here. Projection bugs should still
    # crash visibly rather than masquerading as transcript loss.
    :exit, _reason ->
      Phoenix.PubSub.unsubscribe(Catalyst.PubSub, Server.topic(id))
      start(socket)
  end

  defp attach_new_session(socket, id, pid, model, run_opts) do
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))
    remember_session(id)

    socket
    |> monitor(pid)
    |> Conversation.reset()
    |> assign(
      session_id: id,
      session_pid: pid,
      session_model: model,
      session_opts: run_opts,
      file_search: nil,
      file_refs: %{},
      chat_form: ChatInput.form("")
    )
  end

  defp session_start_failed(socket, reason) do
    Logger.error("[shell] could not start a session: #{inspect(reason)}")
    demonitor(socket.assigns.session_ref)

    socket
    |> assign(
      session_id: nil,
      session_pid: nil,
      session_ref: nil,
      running: false,
      streaming: nil,
      tools: %{}
    )
    |> put_flash(:error, "Could not start a session: #{inspect(reason)}")
  end

  defp stop_attached_session(socket) do
    case socket.assigns.session_id do
      nil ->
        :ok

      id ->
        Phoenix.PubSub.unsubscribe(Catalyst.PubSub, Server.topic(id))
        Manager.stop(id)
    end
  end

  defp monitor(socket, pid) do
    demonitor(socket.assigns.session_ref)
    assign(socket, session_ref: Process.monitor(pid))
  end

  defp demonitor(nil), do: :ok
  defp demonitor(ref), do: Process.demonitor(ref, [:flush])

  defp remember_session(id), do: :persistent_term.put(@session_ptr, %{id: id})

  defp remembered_session do
    case Application.get_env(:catalyst_web, :reattach_sessions, true) do
      true -> :persistent_term.get(@session_ptr, nil)
      false -> nil
    end
  end
end
