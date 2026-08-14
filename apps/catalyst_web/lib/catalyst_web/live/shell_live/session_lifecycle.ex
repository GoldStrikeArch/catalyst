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

  alias Catalyst.Content
  alias Catalyst.Message
  alias Catalyst.Session.{Catalog, Manager, Server}
  alias CatalystWeb.ShellLive.{ChatInput, Conversation, Settings, Threads}

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

  @doc """
  Starts a new session in the current working directory.

  Sibling threads stay alive: the previous `Session.Server` is only
  unfocused, never stopped. The new session becomes the shell's focus.
  """
  @spec start(socket()) :: socket()
  def start(socket), do: start_in(socket, socket.assigns.cwd)

  @doc "Starts a new session at `cwd` without stopping sibling threads."
  @spec start_in(socket(), String.t()) :: socket()
  def start_in(socket, cwd) when is_binary(cwd) do
    socket = release_focus(socket)
    model = Settings.provider_config(socket.assigns.codex_prefs)
    run_opts = Settings.start_opts(socket)

    case Manager.start_session(cwd: cwd, model: model, opts: run_opts) do
      {:ok, %{id: id, pid: pid}} ->
        socket
        |> assign(cwd: cwd)
        |> attach_new_session(id, pid, model, run_opts)
        |> refresh_sidebar()

      {:error, reason} ->
        session_start_failed(socket, reason)
    end
  end

  @doc """
  Focus a cataloged session by id without stopping the previous thread.

  Missing or unreadable catalog entries are a flash; the current focus is
  left attached.
  """
  @spec switch(socket(), String.t()) :: socket()
  def switch(socket, id) when is_binary(id) do
    case socket.assigns.session_id do
      ^id ->
        socket

      _other ->
        case Catalog.lookup(id) do
          {:ok, %{id: ^id, cwd: cwd}} ->
            focus_cataloged(socket, id, cwd)

          {:error, :not_found} ->
            put_flash(socket, :error, "Thread no longer exists.")

          {:error, reason} ->
            put_flash(socket, :error, "Could not open thread: #{inspect(reason)}")
        end
    end
  end

  @doc "Changes the working directory and opens a new thread there."
  @spec change_cwd(socket(), String.t()) :: socket()
  def change_cwd(socket, path) do
    expanded = Path.expand(path, socket.assigns.cwd)

    case File.dir?(expanded) do
      true ->
        socket
        |> ChatInput.put_text("")
        |> start_in(expanded)

      false ->
        put_flash(socket, :error, "Not a directory: #{expanded}")
    end
  end

  @doc "Rebuilds the sidebar assign from the persisted catalog and live pids."
  @spec refresh_sidebar(socket()) :: socket()
  def refresh_sidebar(socket) do
    entries =
      case Catalog.entries() do
        {:ok, list} -> list
        {:error, _reason} -> []
      end

    assign(socket, thread_sidebar: Threads.project(entries, socket.assigns.session_id))
  end

  @doc """
  Stop `id` and drop it from the catalog.

  Closing the focused thread starts a replacement in the same cwd.
  """
  @spec close(socket(), String.t()) :: socket()
  def close(socket, id) when is_binary(id) do
    _ = Manager.stop(id)
    _ = Catalog.forget(id)

    case socket.assigns.session_id do
      ^id -> start_in(socket, socket.assigns.cwd)
      _other -> refresh_sidebar(socket)
    end
  end

  @doc "Persist a thread title from the first real user prompt, if still blank."
  @spec maybe_title(socket(), Message.t()) :: socket()
  def maybe_title(socket, %Message.User{content: content}) do
    maybe_title_text(socket, Content.text_of(content))
  end

  def maybe_title(socket, _message), do: socket

  @doc "Persist `text` as the thread title when the catalog entry is still blank."
  @spec maybe_title_text(socket(), String.t()) :: socket()
  def maybe_title_text(socket, text) when is_binary(text) do
    case Catalog.title_from_text(text) do
      nil ->
        socket

      title ->
        case socket.assigns.session_id do
          nil ->
            socket

          id ->
            _ = Catalog.put_title_if_blank(id, title)
            refresh_sidebar(socket)
        end
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

  @doc "Drop the focused session after it exits, then attach or start a replacement."
  @spec after_exit(socket()) :: socket()
  def after_exit(socket) do
    unsubscribe_topic(socket.assigns.session_id)
    demonitor(socket.assigns.session_ref)

    socket
    |> assign(session_ref: nil, session_id: nil, session_pid: nil, running: false)
    |> attach_or_start()
  end

  defp attach_or_resume(socket) do
    socket =
      case :persistent_term.get(@session_ptr, nil) do
        %{id: id} -> attach_remembered(socket, id)
        _cold -> resume_from_catalog(socket)
      end

    refresh_sidebar(socket)
  end

  defp focus_cataloged(socket, id, cwd) do
    socket = socket |> release_focus() |> assign(cwd: cwd)

    case Manager.whereis(id) do
      {:ok, pid} ->
        remember_session(id, cwd)

        socket
        |> reattach(id, pid)
        |> refresh_sidebar()

      :error ->
        restart_persisted_session(socket, id, cwd)
    end
  end

  # Drop focus of the current thread without stopping it.
  defp release_focus(socket) do
    unsubscribe_topic(socket.assigns.session_id)
    demonitor(socket.assigns.session_ref)
    assign(socket, session_ref: nil, session_pid: nil)
  end

  # Phoenix.PubSub uses a duplicate-keys Registry, so a second subscribe
  # from the same process delivers every event twice.
  defp subscribe_topic(socket, id) do
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))
    socket
  end

  defp unsubscribe_topic(nil), do: :ok

  defp unsubscribe_topic(id) when is_binary(id) do
    Phoenix.PubSub.unsubscribe(Catalyst.PubSub, Server.topic(id))
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
        |> refresh_sidebar()

      {:error, reason} ->
        Logger.warning("[shell] could not resume cataloged session #{id}: #{inspect(reason)}")
        start_in(socket, cwd)
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
    socket
    |> subscribe_topic(id)
    |> monitor(pid)
    |> assign(session_id: id, session_pid: pid)
    |> Conversation.replay(pid)
    |> Settings.sync_from_session()
  catch
    # Only a dead GenServer is recoverable here. Projection bugs should still
    # crash visibly rather than masquerading as transcript loss.
    :exit, _reason ->
      unsubscribe_topic(id)
      start(socket)
  end

  defp attach_new_session(socket, id, pid, model, run_opts) do
    socket = subscribe_topic(socket, id)
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
    # Reconcile the workflow preference from what the session actually got:
    # `Settings.workflow_opts/1` drops a saved name that no longer resolves,
    # and the picker must self-heal to default rather than display a workflow
    # the new session does not have.
    |> Settings.sync_workflow_from_opts(run_opts)
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
