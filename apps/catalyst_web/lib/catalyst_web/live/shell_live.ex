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
  alias CatalystWeb.FolderPicker
  alias CatalystWeb.UI.Registry, as: UIRegistry

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
    codex_prefs = Settings.load_codex()

    socket =
      socket
      |> assign(
        page: "chat",
        chat_form: ChatInput.form(""),
        logged_in: Catalyst.Auth.logged_in?(Settings.auth_provider(codex_prefs)),
        login_state: :idle,
        login_ref: nil,
        login_provider: nil,
        login_label: nil,
        boot_status: Catalyst.Extensions.boot_status(),
        ext_panel: nil,
        ext_action: nil,
        codex_prefs: codex_prefs,
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
        chrome_menu: nil,
        cwd: SessionLifecycle.default_cwd(),
        project_picker: :closed,
        thread_sidebar: %{projects: []}
      )
      |> stream_configure(:prompt_rows, dom_id: & &1.id)
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
    page = route_page(params)

    {:noreply,
     socket
     |> change_page(page)
     |> UIRegistry.prepare_page(page, params)
     |> refresh_shell_chrome()
     |> maybe_refresh_panel()}
  end

  # The Codex catalog and the registered page list only change at discrete
  # points (mount/navigation, Codex control changes, extension actions,
  # session swaps), so they are resolved into assigns there instead of on
  # every render — render/1 runs many times per second while streaming.
  defp refresh_shell_chrome(socket) do
    catalog = Settings.catalog_snapshot(socket.assigns.codex_prefs)

    assign(socket,
      codex_catalog: catalog.models,
      selected_codex_entry: catalog.selected,
      shell_pages: CatalystWeb.UI.Registry.list_pages(),
      runtime_revision: Catalyst.Runtime.Registry.revision()
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

  defp maybe_refresh_panel(%{assigns: %{page: "prompts"}} = socket) do
    stream(
      socket,
      :prompt_rows,
      CatalystWeb.Pages.PromptsPage.panel_data(socket.assigns.codex_catalog),
      reset: true
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

      :queue ->
        queue_prompt(socket, text)
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
    {:noreply, start_thread(socket, socket.assigns.cwd)}
  end

  def handle_event("new_session_in", %{"cwd" => cwd}, socket) when is_binary(cwd) do
    {:noreply, start_thread(socket, cwd)}
  end

  # Sidebar "+": native folder dialog when the shell registered one, else an
  # inline path form. `project_picker` is :closed | :pending | :form.
  def handle_event("pick_project", _params, socket) do
    {:noreply, open_project_picker(socket)}
  end

  def handle_event("open_project", %{"path" => path}, socket) when is_binary(path) do
    {:noreply, open_project(socket, path, :form)}
  end

  def handle_event("cancel_open_project", _params, socket) do
    {:noreply, assign(socket, project_picker: :closed)}
  end

  def handle_event("close_session", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, close_thread(socket, id)}
  end

  def handle_event("switch_session", %{"id" => id}, socket) when is_binary(id) do
    {:noreply,
     socket
     |> assign(diagnostics_open: false, chrome_menu: nil)
     |> SessionLifecycle.switch(id)
     |> RunDiagnostics.preview()
     |> refresh_shell_chrome()
     |> maybe_refresh_panel()}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, Settings.toggle_sidebar(socket)}
  end

  def handle_event("login", _params, %{assigns: %{login_state: :pending}} = socket) do
    {:noreply, socket}
  end

  def handle_event("login", _params, socket) do
    provider = Settings.auth_provider(socket.assigns.codex_prefs)
    label = Settings.auth_label(socket.assigns.codex_prefs)
    login = configured_login_fun(provider, Settings.login_fun(socket.assigns.codex_prefs))
    task = Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, login)

    {:noreply,
     assign(socket,
       login_state: :pending,
       login_ref: task.ref,
       login_provider: provider,
       login_label: label
     )}
  end

  def handle_event("logout", _params, socket) do
    provider = Settings.auth_provider(socket.assigns.codex_prefs)
    label = Settings.auth_label(socket.assigns.codex_prefs)
    Catalyst.Auth.logout(provider)

    {:noreply,
     socket
     |> assign(logged_in: false)
     |> put_flash(:info, "Signed out of #{label}.")}
  end

  def handle_event("codex_opts", params, socket) do
    prefs = Settings.update_codex(socket.assigns.codex_prefs, params)

    {:noreply,
     socket
     |> assign(chrome_menu: nil)
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

  def handle_event("toggle_chrome_menu", %{"menu" => menu}, socket) do
    next = toggle_chrome_menu(socket.assigns.chrome_menu, menu)
    {:noreply, assign(socket, chrome_menu: next, diagnostics_open: false)}
  end

  def handle_event("close_chrome_menu", _params, socket) do
    {:noreply, assign(socket, chrome_menu: nil)}
  end

  def handle_event("save_prompt", %{"target" => encoded, "text" => text}, socket) do
    result =
      with {:ok, target} <- prompt_target(encoded) do
        Catalyst.Prompt.Store.save(target, text)
      end

    {:noreply, finish_prompt_action(socket, result, "Prompt saved for the next run.")}
  end

  def handle_event("delete_prompt", %{"target" => encoded}, socket) do
    result =
      with {:ok, target} <- prompt_target(encoded) do
        Catalyst.Prompt.Store.delete(target)
      end

    {:noreply, finish_prompt_action(socket, result, "Prompt reset to inherited behavior.")}
  end

  def handle_event("toggle_diagnostics", _params, socket) do
    {:noreply,
     assign(socket,
       diagnostics_open: !socket.assigns.diagnostics_open,
       chrome_menu: nil
     )}
  end

  def handle_event("close_diagnostics", _params, socket) do
    {:noreply, assign(socket, diagnostics_open: false, chrome_menu: nil)}
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

  def handle_event(event, params, socket) do
    UIRegistry.dispatch_event(socket.assigns.page, event, params, socket)
  end

  @impl true
  def handle_async(:folder_pick, {:ok, {:ok, path}}, socket) do
    {:noreply, open_project(socket, path, :closed)}
  end

  def handle_async(:folder_pick, {:ok, :cancelled}, socket) do
    {:noreply, assign(socket, project_picker: :closed)}
  end

  def handle_async(:folder_pick, {:ok, {:error, reason}}, socket) do
    {:noreply, folder_pick_failed(socket, reason)}
  end

  def handle_async(:folder_pick, {:exit, reason}, socket) do
    {:noreply, folder_pick_failed(socket, reason)}
  end

  def handle_async({:file_search, _token}, {:ok, result}, socket) do
    {:noreply, ChatInput.apply_search(socket, result)}
  end

  def handle_async({:file_search, token}, {:exit, _reason}, socket) do
    case socket.assigns.file_search_token do
      ^token -> {:noreply, assign(socket, file_search: nil, file_search_token: nil)}
      _superseded -> {:noreply, socket}
    end
  end

  def handle_async(name, result, socket) do
    UIRegistry.dispatch_async(socket.assigns.page, name, result, socket)
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

  def handle_info({:ui_component, module, action}, socket) when is_atom(module) do
    UIRegistry.dispatch_component(module, action, socket)
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
    completed_provider = socket.assigns.login_provider
    label = socket.assigns.login_label
    selected_provider = Settings.auth_provider(socket.assigns.codex_prefs)

    case result do
      {:ok, _account_id} ->
        logged_in =
          case completed_provider == selected_provider do
            true -> true
            false -> Catalyst.Auth.logged_in?(selected_provider)
          end

        {:noreply,
         socket
         |> assign(
           logged_in: logged_in,
           login_state: :idle,
           login_ref: nil,
           login_provider: nil,
           login_label: nil
         )
         |> put_flash(:info, "Signed in to #{label}.")}

      {:error, reason} ->
        message = format_error(reason)

        {:noreply,
         socket
         |> assign(
           login_state: {:error, message},
           login_ref: nil,
           login_provider: nil,
           login_label: nil
         )
         |> put_flash(:error, "Sign-in failed: #{message}")}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{login_ref: ref}} = socket) do
    {:noreply,
     socket
     |> assign(
       login_state: {:error, inspect(reason)},
       login_ref: nil,
       login_provider: nil,
       login_label: nil
     )
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
    socket =
      socket
      |> SessionLifecycle.after_exit()
      |> RunDiagnostics.preview()
      |> refresh_shell_chrome()
      |> maybe_refresh_panel()

    {:noreply, put_flash(socket, :info, "Session was replaced — reattached.")}
  end

  def handle_info(message, socket) do
    UIRegistry.dispatch_info(socket.assigns.page, message, socket)
  end

  @impl true
  def render(assigns), do: CatalystWeb.ShellComponents.render(assigns)

  defp prompt_target("default"), do: {:ok, :default}
  defp prompt_target("append"), do: {:ok, :append}
  defp prompt_target("api:" <> key), do: {:ok, {:api, key}}
  defp prompt_target("model:" <> key), do: {:ok, {:model, key}}
  defp prompt_target(target), do: {:error, {:invalid_prompt_target, target}}

  defp finish_prompt_action(socket, :ok, message) do
    socket
    |> maybe_refresh_panel()
    |> RunDiagnostics.preview()
    |> put_flash(:info, message)
  end

  defp finish_prompt_action(socket, {:error, reason}, _message) do
    put_flash(socket, :error, prompt_error(reason))
  end

  defp prompt_error(:blank_prompt), do: "Prompt cannot be blank. Use Reset to inherit."
  defp prompt_error(:prompt_too_large), do: "Prompt must be 64 KiB or smaller."
  defp prompt_error(reason), do: "Could not save prompt: #{inspect(reason)}"

  defp submission(socket, text) do
    cond do
      text == "" and not ChatInput.completed_images?(socket) ->
        :ignore

      is_nil(socket.assigns.session_pid) ->
        {:error, "No active session — click New to start one."}

      socket.assigns.running ->
        case command_or_prompt(socket, text) do
          :prompt -> :queue
          {:command, _name, _argument} -> {:error, "Wait for the run to finish."}
          other -> other
        end

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
           |> assign(running: true, file_search: nil)
           |> SessionLifecycle.maybe_title_text(text)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Can't start a run: #{inspect(reason)}")}
      end
    catch
      :exit, _reason ->
        {:noreply, put_flash(socket, :error, "Session is restarting — try again.")}
    end
  end

  defp queue_prompt(socket, text) do
    content = ChatInput.consume_prompt(socket, text)

    try do
      :ok = Server.follow_up(socket.assigns.session_pid, content)

      {:noreply,
       socket
       |> ChatInput.put_text("")
       |> assign(file_search: nil, queued: socket.assigns.queued ++ [text])}
    catch
      :exit, _reason ->
        {:noreply, put_flash(socket, :error, "Session is restarting — try again.")}
    end
  end

  defp open_project_picker(%{assigns: %{project_picker: :pending}} = socket), do: socket

  defp open_project_picker(socket) do
    case FolderPicker.available?() do
      true ->
        cwd = socket.assigns.cwd

        socket
        |> assign(project_picker: :pending)
        |> start_async(:folder_pick, fn -> FolderPicker.pick(cwd) end)

      false ->
        assign(socket, project_picker: :form)
    end
  end

  # `on_error` keeps the inline form open so a typo can be fixed in place.
  defp open_project(socket, path, on_error) do
    case SessionLifecycle.project_dir(path, socket.assigns.cwd) do
      {:ok, dir} ->
        socket |> assign(project_picker: :closed) |> start_thread(dir)

      {:error, message} ->
        socket |> assign(project_picker: on_error) |> put_flash(:error, message)
    end
  end

  defp folder_pick_failed(socket, reason) do
    socket
    |> assign(project_picker: :closed)
    |> put_flash(:error, "Could not open the folder picker: #{format_error(reason)}")
  end

  defp start_thread(socket, cwd) do
    socket
    |> assign(diagnostics_open: false, chrome_menu: nil)
    |> SessionLifecycle.start_in(cwd)
    |> RunDiagnostics.preview()
    |> refresh_shell_chrome()
    |> maybe_refresh_panel()
  end

  defp close_thread(socket, id) do
    socket
    |> assign(diagnostics_open: false, chrome_menu: nil)
    |> SessionLifecycle.close(id)
    |> RunDiagnostics.preview()
    |> refresh_shell_chrome()
    |> maybe_refresh_panel()
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

  defp maybe_refresh_after_event(socket, %Event.MessageEnd{message: message}) do
    SessionLifecycle.maybe_title(socket, message)
  end

  defp maybe_refresh_after_event(socket, _event), do: socket

  defp page_path("chat"), do: ~p"/"
  defp page_path(page), do: "/" <> page

  defp route_page(%{"path" => []}), do: "chat"
  defp route_page(%{"path" => segments}) when is_list(segments), do: Enum.join(segments, "/")
  defp route_page(_params), do: "chat"

  defp toggle_chrome_menu(current, "model"), do: toggle_menu(current, :model)
  defp toggle_chrome_menu(current, "effort"), do: toggle_menu(current, :effort)
  defp toggle_chrome_menu(_current, _menu), do: nil

  defp toggle_menu(current, menu) when current == menu, do: nil
  defp toggle_menu(_current, menu), do: menu

  defp configured_login_fun(provider, fallback) do
    :catalyst_web
    |> Application.get_env(:provider_login_funs, %{})
    |> Map.get(provider, Application.get_env(:catalyst_web, :login_fun, fallback))
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
