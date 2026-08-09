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

  alias Catalyst.Session.{Catalog, Manager, Server}
  alias CatalystWeb.ShellLive.{ChatInput, Conversation, Settings}

  @session_ptr {CatalystWeb.ShellLive, :current_session}
  @attach_retries 5
  @attach_retry_delay_ms 20
  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Returns the initial working directory for development or a packaged release."
  @spec default_cwd() :: String.t()
  def default_cwd do
    case Catalyst.Paths.default_cwd() do
      {:ok, cwd} -> cwd
      {:error, reason} -> raise "no usable default working directory: #{inspect(reason)}"
    end
  end

  @doc """
  Reattaches to the remembered live session or starts a replacement.

  The lookup is two-tiered: `:persistent_term` finds the session while the VM
  that started it is still running; after a full VM restart the persisted
  `Catalyst.Session.Catalog` supplies the `{id, cwd}` pair the store needs to
  resume the transcript from disk.
  """
  @spec attach_or_start(socket()) :: socket()
  def attach_or_start(socket) do
    case reattach_enabled?() do
      true -> attach_or_resume(socket)
      false -> start(socket)
    end
  end

  @doc "Starts a new session, replacing the one currently attached to the shell."
  @spec start(socket()) :: socket()
  def start(socket) do
    stop_attached_session(socket)

    model = Settings.provider_config(socket.assigns.codex_prefs)
    run_opts = Settings.start_opts(socket)

    case Manager.start_session(
           cwd: socket.assigns.cwd,
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

  @doc """
  Retries attaching to a remembered session that was not yet registered.

  Called by ShellLive when a `{:retry_session_attach, id, retries_left}` timer
  message (scheduled below) arrives; retries stay bounded and the final miss
  falls back to a fresh session.
  """
  @spec retry_attach(socket(), String.t(), non_neg_integer()) :: socket()
  def retry_attach(socket, id, retries_left), do: try_attach(socket, id, retries_left)

  defp attach_or_resume(socket) do
    case :persistent_term.get(@session_ptr, nil) do
      %{id: id} -> attach_remembered(socket, id)
      _cold -> resume_from_catalog(socket)
    end
  end

  # After a full VM restart the :persistent_term pointer is gone but the
  # catalog still knows the {id, cwd} pair the store derives its path from.
  # Any miss (empty or unreadable catalog, deleted cwd) starts fresh.
  defp resume_from_catalog(socket) do
    case Catalog.most_recent() do
      {:ok, %{id: id, cwd: cwd}} -> resume_persisted(socket, id, cwd)
      {:error, _empty_or_unreadable} -> start(socket)
    end
  end

  defp resume_persisted(socket, id, cwd) do
    case File.dir?(cwd) do
      true -> restart_persisted_session(socket, id, cwd)
      false -> start(socket)
    end
  end

  # Manager.start_session/1 with an explicit id adopts the process when it is
  # somehow still alive and otherwise reopens the on-disk transcript, so this
  # one call covers both the warm and the restarted-VM case.
  defp restart_persisted_session(socket, id, cwd) do
    model = Settings.provider_config(socket.assigns.codex_prefs)
    run_opts = Settings.start_opts(socket)

    case Manager.start_session(id: id, cwd: cwd, model: model, opts: run_opts) do
      {:ok, %{id: ^id, pid: pid}} ->
        remember_session(id, cwd)

        socket
        |> assign(cwd: cwd)
        |> reattach(id, pid)

      {:error, reason} ->
        Logger.warning("[shell] could not resume cataloged session #{id}: #{inspect(reason)}")
        start(socket)
    end
  end

  defp attach_remembered(socket, id), do: try_attach(socket, id, @attach_retries)

  defp try_attach(socket, id, retries_left) do
    case Manager.whereis(id) do
      {:ok, pid} ->
        reattach(socket, id, pid)

      :error when retries_left > 0 ->
        # The remembered server may still be (re)registering. Schedule a
        # bounded retry through the mailbox instead of sleep-polling inside
        # the LiveView process; ShellLive routes the message back here.
        Process.send_after(
          self(),
          {:retry_session_attach, id, retries_left - 1},
          @attach_retry_delay_ms
        )

        socket

      :error ->
        # A crashed child can re-register under the abandoned id after this
        # lookup. Stop it before moving the UI to a new session.
        Manager.stop(id)
        start(socket)
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
    remember_session(id, socket.assigns.cwd)

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

  # The :persistent_term pointer serves same-VM reconnects; the write-through
  # to the persisted catalog is what makes resume survive a VM restart. A
  # catalog write failure only degrades restart-resume, so it is logged, not
  # propagated.
  defp remember_session(id, cwd) do
    :persistent_term.put(@session_ptr, %{id: id})

    case Catalog.remember(id, cwd) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[shell] could not persist session catalog entry: #{inspect(reason)}")
    end
  end

  defp reattach_enabled?, do: Application.get_env(:catalyst_web, :reattach_sessions, true)
end
