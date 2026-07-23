defmodule CatalystWeb.ShellLive do
  @moduledoc """
  The persistent LiveView shell mounted at `/` and `/:page`.

  `ShellLive` is the process boundary for browser events, session PubSub, task
  results, and session monitors. Cohesive state transitions live in focused
  modules under `CatalystWeb.ShellLive`, while stateless chrome lives in
  `CatalystWeb.ShellComponents`. Runtime pages, renderers, slot components, and
  commands continue to resolve through `CatalystWeb.UI.Registry` on every use.

  Sessions outlive the LiveView. A reconnect or UI reload reattaches to the
  current `Catalyst.Session.Server`, subscribes before taking its snapshot, and
  rebuilds the transient conversation projection without losing an in-flight run.
  """

  use CatalystWeb, :live_view

  alias Catalyst.Agent.Event
  alias Catalyst.Session.Server
  alias CatalystWeb.Assets

  alias CatalystWeb.ShellLive.{
    ChatInput,
    Commands,
    Conversation,
    ExtensionActions,
    RunDiagnostics,
    SessionLifecycle,
    Settings
  }

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page: "chat",
        chat_form: ChatInput.form(""),
        logged_in: Catalyst.Auth.logged_in?(),
        login_state: :idle,
        login_ref: nil,
        boot_status: Catalyst.Extensions.boot_status(),
        ext_panel: nil,
        ext_action: nil,
        codex_prefs: Settings.load_codex(),
        ui_prefs: Settings.load_ui(),
        session_model: nil,
        session_opts: [],
        file_search: nil,
        file_search_token: nil,
        file_refs: %{},
        session_id: nil,
        session_pid: nil,
        session_ref: nil,
        prompt_preview: nil,
        prompt_preview_ref: nil,
        prompt_preview_pid: nil,
        diagnostics_open: false,
        cwd: SessionLifecycle.default_cwd()
      )
      |> Conversation.init()
      |> allow_upload(:image,
        accept: ~w(.png .jpg .jpeg .gif .webp),
        max_entries: 4,
        max_file_size: 5_000_000,
        auto_upload: true
      )

    case connected?(socket) do
      true ->
        Phoenix.PubSub.subscribe(Catalyst.PubSub, Assets.topic())

        {:ok,
         socket
         |> SessionLifecycle.attach_or_start()
         |> RunDiagnostics.preview()}

      false ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = Map.get(params, "page", "chat")

    {:noreply,
     socket
     |> change_page(page)
     |> refresh_shell_chrome()
     |> maybe_refresh_panel()}
  end

  # The Codex catalog and the registered page list only change at discrete
  # points (mount/navigation, Codex control changes, extension actions,
  # session swaps), so they are resolved into assigns there instead of on
  # every render — render/1 runs many times per second while streaming.
  defp refresh_shell_chrome(socket) do
    catalog = Catalyst.LLM.OpenAICodex.catalog_snapshot(socket.assigns.codex_prefs.model)

    assign(socket,
      codex_catalog: catalog.models,
      selected_codex_entry: catalog.selected,
      shell_pages: CatalystWeb.UI.Registry.list_pages()
    )
  end

  # Returning to chat recreates a DOM-backed stream that disappeared while a
  # different page was active, so replay the authoritative session snapshot.
  defp change_page(%{assigns: %{page: old_page, session_pid: pid}} = socket, "chat")
       when old_page != "chat" and is_pid(pid) do
    socket = assign(socket, page: "chat")

    try do
      Conversation.replay(socket, pid)
    catch
      # The session monitor callback will recover a server that died mid-replay.
      :exit, _reason -> socket
    end
  end

  defp change_page(socket, page), do: assign(socket, page: page)

  defp maybe_refresh_panel(%{assigns: %{page: "extensions"}} = socket) do
    assign(socket,
      ext_panel:
        CatalystWeb.Pages.ExtensionsPage.panel_data(
          socket.assigns.session_model,
          socket.assigns.session_opts,
          %{
            context_status: socket.assigns.context_status,
            run_metadata: socket.assigns.run_metadata
          }
        ),
      boot_status: Catalyst.Extensions.boot_status()
    )
  end

  defp maybe_refresh_panel(socket), do: socket

  # Sessions intentionally are not stopped from terminate/2. Reconnects, page
  # refreshes, and self-triggered UI reloads must be able to reattach.

  @impl true
  def handle_event("typing", %{"message" => text}, socket) do
    {:noreply,
     socket
     |> ChatInput.put_text(text)
     |> ChatInput.search_files(text)}
  end

  # Enter selects the first active `@` result rather than submitting an
  # unresolved search token to the model.
  def handle_event(
        "send",
        %{"message" => text},
        %{assigns: %{file_search: %{results: [first | _results]}}} = socket
      ) do
    {:noreply, ChatInput.pick_file(socket, text, first.label, first.path)}
  end

  def handle_event("send", %{"message" => text}, socket) do
    text =
      socket.assigns.file_refs
      |> ChatInput.expand_refs(String.trim(text))
      |> String.trim()

    case submission(socket, text) do
      :ignore ->
        {:noreply, socket}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}

      {:command, name, argument} ->
        # Command handlers are an extension boundary: they can swap the
        # session (/cd) or mutate the UI registry, so refresh the chrome.
        {:noreply,
         name
         |> Commands.dispatch(argument, socket)
         |> RunDiagnostics.preview()
         |> refresh_shell_chrome()}

      :prompt ->
        submit_prompt(socket, text)
    end
  end

  def handle_event("cancel_image", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :image, ref)}
  end

  def handle_event("pick_file", %{"label" => label, "path" => path}, socket) do
    text = socket.assigns.chat_form.params["message"] || ""
    {:noreply, ChatInput.pick_file(socket, text, label, path)}
  end

  def handle_event("abort", _params, socket) do
    case socket.assigns.session_pid do
      pid when is_pid(pid) -> Server.abort(pid)
      _no_session -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("new_session", _params, socket) do
    {:noreply,
     socket
     |> SessionLifecycle.start()
     |> RunDiagnostics.preview()
     |> refresh_shell_chrome()
     |> maybe_refresh_panel()}
  end

  def handle_event("login", _params, %{assigns: %{login_state: :pending}} = socket) do
    {:noreply, socket}
  end

  def handle_event("login", _params, socket) do
    task = Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, login_fun())
    {:noreply, assign(socket, login_state: :pending, login_ref: task.ref)}
  end

  def handle_event("logout", _params, socket) do
    Catalyst.Auth.logout()

    {:noreply,
     socket
     |> assign(logged_in: false)
     |> put_flash(:info, "Signed out.")}
  end

  def handle_event("codex_opts", params, socket) do
    prefs = Settings.update_codex(socket.assigns.codex_prefs, params)

    {:noreply,
     socket
     |> Settings.apply_codex(prefs)
     |> RunDiagnostics.preview()
     |> refresh_shell_chrome()
     |> maybe_refresh_panel()}
  end

  def handle_event("codex_fast", _params, socket) do
    prefs = Settings.toggle_fast(socket.assigns.codex_prefs)

    {:noreply,
     socket
     |> Settings.apply_codex(prefs)
     |> RunDiagnostics.preview()
     |> refresh_shell_chrome()
     |> maybe_refresh_panel()}
  end

  def handle_event("toggle_quiet", _params, socket) do
    {:noreply, Settings.toggle_quiet(socket)}
  end

  def handle_event("toggle_diagnostics", _params, socket) do
    {:noreply, assign(socket, diagnostics_open: !socket.assigns.diagnostics_open)}
  end

  # Extension compilation and git operations run one at a time in supervised
  # tasks; this clause catches clicks already queued while an action was active.
  def handle_event("ext_" <> _action, _params, %{assigns: %{ext_action: %{}}} = socket) do
    {:noreply, socket}
  end

  def handle_event("ext_reload_all", _params, socket) do
    {:noreply, ExtensionActions.start(socket, :reload_all)}
  end

  def handle_event("ext_rollback_last", _params, socket) do
    {:noreply, ExtensionActions.start(socket, :rollback_last)}
  end

  def handle_event("ext_reload", %{"owner" => owner}, socket) do
    {:noreply, ExtensionActions.start(socket, {:reload, owner})}
  end

  def handle_event("ext_rollback", %{"owner" => owner}, socket) do
    {:noreply, ExtensionActions.start(socket, {:rollback, owner})}
  end

  def handle_event("ext_disable", %{"owner" => owner}, socket) do
    {:noreply, ExtensionActions.start(socket, {:disable, owner})}
  end

  def handle_event("ext_enable", %{"owner" => owner}, socket) do
    {:noreply, ExtensionActions.start(socket, {:enable, owner})}
  end

  @impl true
  def handle_async({:file_search, _token}, {:ok, result}, socket) do
    {:noreply, ChatInput.apply_search(socket, result)}
  end

  def handle_async({:file_search, token}, {:exit, _reason}, socket) do
    case socket.assigns.file_search_token do
      ^token -> {:noreply, assign(socket, file_search: nil, file_search_token: nil)}
      _superseded -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:agent_event, id, event}, socket) do
    case id == socket.assigns.session_id do
      true ->
        socket =
          event
          |> Conversation.apply_event(socket)
          |> maybe_refresh_after_event(event)

        {:noreply, socket}

      false ->
        {:noreply, socket}
    end
  end

  def handle_info(:reload_assets, socket) do
    {:noreply, redirect(socket, to: page_path(socket.assigns.page))}
  end

  def handle_info({ref, result}, %{assigns: %{prompt_preview_ref: ref}} = socket) do
    Process.demonitor(ref, [:flush])
    {:noreply, RunDiagnostics.finish_preview(socket, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{assigns: %{prompt_preview_ref: ref}} = socket
      ) do
    {:noreply, RunDiagnostics.finish_preview(socket, {:error, {:preview_exit, reason}})}
  end

  def handle_info({ref, result}, %{assigns: %{login_ref: ref}} = socket) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, _account_id} ->
        {:noreply,
         socket
         |> assign(logged_in: true, login_state: :idle, login_ref: nil)
         |> put_flash(:info, "Signed in to ChatGPT.")}

      {:error, reason} ->
        message = format_error(reason)

        {:noreply,
         socket
         |> assign(login_state: {:error, message}, login_ref: nil)
         |> put_flash(:error, "Sign-in failed: #{message}")}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{login_ref: ref}} = socket) do
    {:noreply,
     socket
     |> assign(login_state: {:error, inspect(reason)}, login_ref: nil)
     |> put_flash(:error, "Sign-in crashed.")}
  end

  def handle_info({ref, result}, %{assigns: %{ext_action: %{ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])

    # Reload/rollback/disable can change prompt registrations, registered
    # pages, and the model catalog, so the resolved preview and the shell
    # chrome must be recomputed along with the panel snapshot.
    socket =
      socket
      |> assign(ext_action: nil)
      |> refresh_shell_chrome()
      |> maybe_refresh_panel()
      |> RunDiagnostics.preview()

    case result do
      {:ok, message} -> {:noreply, put_flash(socket, :info, message)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{assigns: %{ext_action: %{ref: ref}}} = socket
      ) do
    {:noreply,
     socket
     |> assign(ext_action: nil)
     |> refresh_shell_chrome()
     |> maybe_refresh_panel()
     |> put_flash(:error, "Extension action crashed: #{inspect(reason)}")}
  end

  # Scheduled by SessionLifecycle when a remembered session id was not yet
  # registered at mount; retries are bounded and stop once a session attached.
  def handle_info({:retry_session_attach, id, retries_left}, socket) do
    case socket.assigns.session_pid do
      nil ->
        socket = SessionLifecycle.retry_attach(socket, id, retries_left)

        case socket.assigns.session_pid do
          nil -> {:noreply, socket}
          _attached -> {:noreply, RunDiagnostics.preview(socket)}
        end

      _attached ->
        {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{assigns: %{session_ref: ref}} = socket) do
    unsubscribe_session(socket.assigns.session_id)

    socket =
      socket
      |> assign(session_ref: nil, session_id: nil, session_pid: nil, running: false)
      |> SessionLifecycle.attach_or_start()
      |> RunDiagnostics.preview()
      |> refresh_shell_chrome()
      |> maybe_refresh_panel()

    {:noreply, put_flash(socket, :info, "Session was replaced — reattached.")}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns), do: CatalystWeb.ShellComponents.render(assigns)

  defp submission(socket, text) do
    cond do
      socket.assigns.running ->
        :ignore

      text == "" and not ChatInput.completed_images?(socket) ->
        :ignore

      is_nil(socket.assigns.session_pid) ->
        {:error, "No active session — click New to start one."}

      true ->
        command_or_prompt(socket, text)
    end
  end

  defp command_or_prompt(socket, text) do
    case Commands.parse(text) do
      {:ok, name, argument} ->
        {:command, name, argument}

      :error ->
        case ChatInput.uploading_images?(socket) do
          true -> {:error, "Images are still uploading — try again in a moment."}
          false -> :prompt
        end
    end
  end

  defp submit_prompt(socket, text) do
    content = ChatInput.consume_prompt(socket, text)

    try do
      case Server.prompt(socket.assigns.session_pid, content) do
        :ok ->
          {:noreply,
           socket
           |> ChatInput.put_text("")
           |> assign(running: true, file_search: nil)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Can't start a run: #{inspect(reason)}")}
      end
    catch
      :exit, _reason ->
        {:noreply, put_flash(socket, :error, "Session is restarting — try again.")}
    end
  end

  defp maybe_refresh_after_event(socket, %Event.ContextStatus{}) do
    RunDiagnostics.refresh(socket, preserve_status: true)
  end

  defp maybe_refresh_after_event(socket, %Event.AgentStart{}),
    do: RunDiagnostics.refresh(socket)

  defp maybe_refresh_after_event(socket, %Event.AgentEnd{}) do
    socket
    |> RunDiagnostics.refresh()
    |> maybe_refresh_panel()
  end

  defp maybe_refresh_after_event(socket, _event), do: socket

  defp unsubscribe_session(nil), do: :ok

  defp unsubscribe_session(id) do
    Phoenix.PubSub.unsubscribe(Catalyst.PubSub, Server.topic(id))
  end

  defp page_path("chat"), do: ~p"/"
  defp page_path(page), do: ~p"/#{page}"

  defp login_fun do
    Application.get_env(:catalyst_web, :login_fun, &Catalyst.Auth.login_openai_codex/0)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
