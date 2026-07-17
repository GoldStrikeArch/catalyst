defmodule CatalystWeb.ShellLive do
  @moduledoc """
  The single LiveView for the whole app, mounted at `/` and `/:page`. On connect
  it reattaches to the app's current `Catalyst.Session.Server` (or starts one),
  subscribes to its `"session:<id>"` topic, and renders the shell chrome (title,
  provider/login, page nav) plus the **active page** resolved from
  `CatalystWeb.UI.Registry`. Sessions outlive the LiveView, so reconnects and
  self-triggered UI reloads resume the conversation instead of discarding it.

  The default page is `"chat"` (`CatalystWeb.Pages.ChatPage`); extensions can
  register additional pages (e.g. `/settings`) at runtime with no router change.
  All page content is rendered through the registry, and conversation messages
  through `CatalystWeb.UI.MessageRenderer`, so the UI is runtime-extensible.
  """
  use CatalystWeb, :live_view
  require Logger

  alias Catalyst.Message
  alias Catalyst.Agent.Event
  alias Catalyst.Session.{Manager, Server}
  alias CatalystWeb.{Assets, UI}

  # The system prompt is intentionally NOT set here: leaving the session's
  # :system_prompt nil makes Session.Server resolve Catalyst.SystemPrompt.get/0
  # fresh on every run (~/.catalyst/system_prompt.md override → built-in default),
  # so the prompt is editable data, not compiled-in UI code.

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page: "chat",
        streaming: nil,
        running: false,
        tools: %{},
        input: "",
        chat_form: chat_form(""),
        logged_in: Catalyst.Auth.logged_in?(),
        login_state: :idle,
        login_ref: nil,
        boot_status: Catalyst.Extensions.boot_status(),
        provider: :demo,
        model_label: "Demo (offline)",
        session_id: nil,
        session_pid: nil,
        # Monitor on the attached session, so a replaced/crashed session leads
        # to a graceful reattach instead of calls to a dead pid.
        session_ref: nil,
        # Dedup window for events re-received right after a reattach.
        replayed_tail: [],
        cwd: default_cwd(),
        # Conversation is a LiveView stream (append-only), so the socket never
        # retains the full transcript. `message_seq` is a monotonic counter used
        # as the stable DOM id (messages carry no id of their own); `message_count`
        # drives the empty state.
        message_seq: 0,
        message_count: 0
      )
      |> stream(:messages, [])

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Catalyst.PubSub, Assets.topic())
      {:ok, attach_or_start(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, page: Map.get(params, "page", "chat"))}

  # No terminate/2 session cleanup: the session outlives the LiveView so a
  # reconnect, page refresh, or self-triggered reload (reload_ui/rebuild_assets)
  # reattaches instead of killing the conversation — including an in-flight run.
  # Sessions are stopped explicitly when a new one replaces them (start_session).

  # ---- events ---------------------------------------------------------------

  @impl true
  def handle_event("typing", %{"message" => text}, socket),
    do: {:noreply, assign_input(socket, text)}

  def handle_event("send", %{"message" => text}, socket) do
    text = String.trim(text)

    cond do
      text == "" or socket.assigns.running ->
        {:noreply, socket}

      # A bare `/cd` is a mistyped command, not a prompt for the model.
      text == "/cd" ->
        {:noreply, put_flash(socket, :error, "usage: /cd <path>")}

      # `/cd <path>` points the session at a different working directory.
      String.starts_with?(text, "/cd ") ->
        {:noreply, set_cwd(socket, text |> String.replace_prefix("/cd ", "") |> String.trim())}

      true ->
        try do
          case Server.prompt(socket.assigns.session_pid, text) do
            :ok ->
              {:noreply, socket |> assign_input("") |> assign(running: true)}

            # e.g. {:error, :no_provider} — keep the typed text and explain.
            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Can't start a run: #{inspect(reason)}")}
          end
        catch
          # The session died (e.g. another window replaced it) — the :DOWN
          # handler reattaches; keep the typed text so nothing is lost.
          :exit, _reason ->
            {:noreply, put_flash(socket, :error, "Session is restarting — try again.")}
        end
    end
  end

  def handle_event("abort", _params, socket) do
    if socket.assigns.session_pid, do: Server.abort(socket.assigns.session_pid)
    {:noreply, socket}
  end

  def handle_event("new_session", _params, socket),
    do: {:noreply, start_session(socket, socket.assigns.provider)}

  # Re-clicking the active provider must be a no-op: starting a new session
  # would wipe the current conversation.
  def handle_event("set_provider", %{"provider" => "codex"}, socket) do
    cond do
      socket.assigns.provider == :codex ->
        {:noreply, socket}

      socket.assigns.logged_in ->
        {:noreply, start_session(socket, :codex)}

      true ->
        {:noreply, put_flash(socket, :error, "Not signed in. Run `mix catalyst.login` first.")}
    end
  end

  def handle_event("set_provider", %{"provider" => _demo}, socket) do
    case socket.assigns.provider do
      :demo -> {:noreply, socket}
      _other -> {:noreply, start_session(socket, :demo)}
    end
  end

  # Run the ChatGPT OAuth flow in a supervised Task so the LiveView doesn't block
  # while the user completes login in their browser. Result arrives via handle_info.
  def handle_event("login", _params, %{assigns: %{login_state: :pending}} = socket),
    do: {:noreply, socket}

  def handle_event("login", _params, socket) do
    fun = login_fun()
    task = Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fun)
    {:noreply, assign(socket, login_state: :pending, login_ref: task.ref)}
  end

  def handle_event("logout", _params, socket) do
    Catalyst.Auth.logout()
    socket = if socket.assigns.provider == :codex, do: start_session(socket, :demo), else: socket
    {:noreply, assign(socket, logged_in: false) |> put_flash(:info, "Signed out.")}
  end

  # ---- info -----------------------------------------------------------------

  @impl true
  def handle_info({:agent_event, event}, socket), do: {:noreply, apply_event(event, socket)}

  # An asset rebuild happened — full reload so the new app.js/app.css are
  # fetched. Reload the page the user is on, not "/", or every non-chat page
  # would be kicked back to chat.
  def handle_info(:reload_assets, socket),
    do: {:noreply, redirect(socket, to: page_path(socket.assigns.page))}

  # Login task finished (matches only when the ref is our pending login task).
  def handle_info({ref, result}, %{assigns: %{login_ref: ref}} = socket) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, _account_id} ->
        socket
        |> assign(logged_in: true, login_state: :idle, login_ref: nil)
        |> put_flash(:info, "Signed in to ChatGPT.")
        |> start_session(:codex)
        |> then(&{:noreply, &1})

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(login_state: {:error, format_error(reason)}, login_ref: nil)
         |> put_flash(:error, "Sign-in failed: #{format_error(reason)}")}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{login_ref: ref}} = socket) do
    {:noreply,
     socket
     |> assign(login_state: {:error, inspect(reason)}, login_ref: nil)
     |> put_flash(:error, "Sign-in crashed.")}
  end

  # The session this view is attached to died or was replaced (e.g. another
  # window started a new one) — reattach to whatever is current instead of
  # holding a dead pid (the next send would crash the LiveView).
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{assigns: %{session_ref: ref}} = socket) do
    if id = socket.assigns.session_id do
      Phoenix.PubSub.unsubscribe(Catalyst.PubSub, Server.topic(id))
    end

    socket =
      socket
      |> assign(session_ref: nil, session_id: nil, session_pid: nil, running: false)
      |> attach_or_start()

    {:noreply, put_flash(socket, :info, "Session was replaced — reattached.")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The browser path for a page name (mirrors the router: "/" + "/:page").
  defp page_path("chat"), do: "/"
  defp page_path(page), do: "/#{page}"

  # Overridable so tests can stub the OAuth flow.
  defp login_fun,
    do: Application.get_env(:catalyst_web, :login_fun, &Catalyst.Auth.login_openai_codex/0)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp chat_form(input), do: to_form(%{"message" => input})

  defp assign_input(socket, text), do: assign(socket, input: text, chat_form: chat_form(text))

  defp apply_event(%Event.MessageStart{message: %Message.Assistant{}}, socket),
    do: assign(socket, streaming: true)

  defp apply_event(
         %Event.MessageUpdate{llm_event: %Catalyst.LLM.Event.TextDelta{delta: d}},
         socket
       ),
       do: push_stream_delta(socket, "text", d)

  defp apply_event(
         %Event.MessageUpdate{llm_event: %Catalyst.LLM.Event.ThinkingDelta{delta: d}},
         socket
       ),
       do: push_stream_delta(socket, "thinking", d)

  defp apply_event(%Event.MessageEnd{message: message}, socket) do
    # A MessageEnd broadcast between reattach's subscribe and snapshot call
    # arrives again here; duplicates form an in-order suffix of the replayed
    # snapshot tail. Drop them; the first genuinely new message ends the window.
    case split_replayed(socket.assigns.replayed_tail, :erlang.phash2(message)) do
      {:duplicate, rest} ->
        assign(socket, replayed_tail: rest)

      :new ->
        streaming =
          if match?(%Message.Assistant{}, message), do: nil, else: socket.assigns.streaming

        seq = socket.assigns.message_seq + 1

        socket
        |> assign(
          streaming: streaming,
          message_seq: seq,
          message_count: socket.assigns.message_count + 1,
          replayed_tail: []
        )
        |> stream_insert(:messages, %{id: seq, msg: message})
    end
  end

  defp apply_event(%Event.ToolExecutionStart{call_id: id, name: name, args: args}, socket),
    do: assign(socket, tools: Map.put(socket.assigns.tools, id, %{name: name, args: args}))

  defp apply_event(%Event.ToolExecutionEnd{call_id: id}, socket),
    do: assign(socket, tools: Map.delete(socket.assigns.tools, id))

  # Also clear tool spinners: an aborted/failed run never emits
  # ToolExecutionEnd for its pending calls.
  defp apply_event(%Event.AgentEnd{}, socket),
    do: assign(socket, running: false, streaming: nil, tools: %{})

  defp apply_event(_event, socket), do: socket

  # Send only the delta; the StreamingMessage JS hook appends it client-side,
  # so wire traffic stays O(total text) instead of O(n²).
  defp push_stream_delta(socket, kind, delta) do
    socket
    |> ensure_streaming()
    |> push_event("stream_delta", %{kind: kind, delta: delta})
  end

  # A delta with no open bubble (e.g. reattached mid-stream) still gets one.
  defp ensure_streaming(socket) do
    if socket.assigns.streaming, do: socket, else: assign(socket, streaming: true)
  end

  defp split_replayed([], _hash), do: :new

  defp split_replayed(tail, hash) do
    case Enum.split_while(tail, &(&1 != hash)) do
      {_skipped, [^hash | rest]} -> {:duplicate, rest}
      _ -> :new
    end
  end

  # ---- session lifecycle ----------------------------------------------------

  # The most recent session for this (single-user) app instance. A remounting
  # LiveView — reconnect, refresh, or a self-triggered UI reload — reattaches to
  # it instead of starting over.
  @session_ptr {__MODULE__, :current_session}

  defp remember_session(id, provider),
    do: :persistent_term.put(@session_ptr, %{id: id, provider: provider})

  defp remembered_session do
    if Application.get_env(:catalyst_web, :reattach_sessions, true) do
      :persistent_term.get(@session_ptr, nil)
    end
  end

  defp attach_or_start(socket) do
    with %{id: id, provider: provider} <- remembered_session(),
         pid when is_pid(pid) <- Manager.whereis(id) do
      reattach_session(socket, id, pid, provider)
    else
      _ -> start_session(socket, :demo)
    end
  end

  # Rebuild the UI from the live server's snapshot: replay the transcript into
  # the stream and pick up an in-flight run (its events keep arriving via PubSub).
  # Subscribe BEFORE snapshotting so no event can fall in between: anything
  # broadcast before the snapshot answered arrives again via PubSub and is
  # dropped by the replayed_tail dedup (see the MessageEnd apply_event clause).
  defp reattach_session(socket, id, pid, provider) do
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))
    snapshot = Server.state(pid)
    {_mod, _model, label} = provider_config(provider)

    {socket, seq} =
      Enum.reduce(snapshot.messages, {stream(socket, :messages, [], reset: true), 0}, fn
        msg, {sock, seq} -> {stream_insert(sock, :messages, %{id: seq + 1, msg: msg}), seq + 1}
      end)

    socket
    |> monitor_session(pid)
    |> assign(
      session_id: id,
      session_pid: pid,
      provider: provider,
      model_label: label,
      cwd: snapshot.cwd,
      running: snapshot.running,
      streaming: nil,
      tools: %{},
      message_seq: seq,
      message_count: seq,
      replayed_tail: snapshot.messages |> Enum.take(-10) |> Enum.map(&:erlang.phash2/1)
    )
    |> seed_streaming(snapshot.streaming_message)
  catch
    # The server died between whereis and the state call — start fresh.
    kind, _reason when kind in [:exit, :error] ->
      Phoenix.PubSub.unsubscribe(Catalyst.PubSub, Server.topic(id))
      start_session(socket, :demo)
  end

  # Rebuild the in-flight bubble from the snapshot's accumulated deltas, so a
  # mid-stream UI reload doesn't lose already-streamed text (new deltas keep
  # appending client-side after these).
  defp seed_streaming(socket, %Message.Assistant{content: [_ | _] = blocks}) do
    Enum.reduce(blocks, socket, fn
      %Catalyst.Content.Thinking{thinking: t}, sock -> push_stream_delta(sock, "thinking", t)
      %Catalyst.Content.Text{text: t}, sock -> push_stream_delta(sock, "text", t)
      _block, sock -> sock
    end)
  end

  defp seed_streaming(socket, _none), do: socket

  defp start_session(socket, provider) do
    if old_id = socket.assigns.session_id do
      Phoenix.PubSub.unsubscribe(Catalyst.PubSub, Server.topic(old_id))
      Manager.stop(old_id)
    end

    {provider_mod, model, label} = provider_config(provider)

    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(
        cwd: socket.assigns.cwd,
        provider: provider_mod,
        model: model
      )

    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))
    remember_session(id, provider)

    socket
    |> monitor_session(pid)
    |> assign(
      session_id: id,
      session_pid: pid,
      provider: provider,
      model_label: label,
      streaming: nil,
      running: false,
      tools: %{},
      message_seq: 0,
      message_count: 0,
      replayed_tail: [],
      input: "",
      chat_form: chat_form("")
    )
    |> stream(:messages, [], reset: true)
  end

  # One monitor per attached session: the :DOWN handler reattaches gracefully
  # when the session is stopped from elsewhere (another window) or crashes.
  defp monitor_session(socket, pid) do
    if ref = socket.assigns.session_ref, do: Process.demonitor(ref, [:flush])
    assign(socket, session_ref: Process.monitor(pid))
  end

  defp provider_config(:codex) do
    model = Catalyst.LLM.OpenAICodex.model()
    {Catalyst.LLM.OpenAICodex.Provider, model, "Codex · #{model.id}"}
  end

  defp provider_config(_demo),
    do: {Catalyst.LLM.Demo, Catalyst.LLM.Demo.model(), "Demo (offline)"}

  # In a packaged release the launch dir is inside the .app bundle (the erts dir),
  # which is useless to work in — default to the user's home instead. In dev, the
  # umbrella root (File.cwd!()) is correct. The user can change it (set_cwd).
  defp default_cwd do
    case System.get_env("RELEASE_NAME") do
      nil -> File.cwd!()
      _ -> System.user_home!()
    end
  end

  # Point the session at a different working directory and restart it there.
  defp set_cwd(socket, path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      socket
      |> assign(cwd: expanded)
      |> assign_input("")
      |> start_session(socket.assigns.provider)
    else
      put_flash(socket, :error, "Not a directory: #{expanded}")
    end
  end

  # ---- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} class="min-h-screen bg-slate-950 text-slate-950 dark:text-slate-50">
      <div
        id="catalyst-shell"
        data-session-id={@session_id || ""}
        class="flex h-screen flex-col bg-[radial-gradient(circle_at_top_left,rgba(99,102,241,0.16),transparent_32rem),linear-gradient(135deg,#f8fafc,#eef2ff_45%,#f8fafc)] dark:bg-[radial-gradient(circle_at_top_left,rgba(129,140,248,0.20),transparent_32rem),linear-gradient(135deg,#020617,#0f172a_45%,#111827)]"
      >
        <header class="flex min-h-14 items-center gap-3 border-b border-slate-200/80 bg-white/80 px-4 shadow-sm shadow-slate-200/60 backdrop-blur dark:border-white/10 dark:bg-slate-950/70 dark:shadow-black/20">
          <div class="flex min-w-0 flex-1 items-center gap-2">
            <span class="text-lg font-bold tracking-tight text-slate-950 dark:text-white">
              Catalyst
            </span>
            <span class="rounded-full border border-slate-200 bg-white/70 px-2 py-0.5 text-xs font-medium text-slate-500 dark:border-white/10 dark:bg-white/10 dark:text-slate-300">
              {@model_label}
            </span>
            <span :if={@running} class="flex items-center gap-1" aria-label="Agent running">
              <span class="size-1.5 animate-pulse rounded-full bg-indigo-500"></span>
              <span class="size-1.5 animate-pulse rounded-full bg-indigo-500 delay-150"></span>
              <span class="size-1.5 animate-pulse rounded-full bg-indigo-500 delay-300"></span>
            </span>

            <nav :if={length(UI.Registry.list_pages()) > 1} class="ml-3 flex items-center gap-1">
              <.link
                :for={p <- UI.Registry.list_pages()}
                patch={~p"/#{p.path}"}
                class={[
                  "rounded-full px-3 py-1 text-xs font-medium transition",
                  @page == p.path && "bg-slate-950 text-white dark:bg-white dark:text-slate-950",
                  @page != p.path &&
                    "text-slate-500 hover:bg-slate-100 hover:text-slate-950 dark:text-slate-300 dark:hover:bg-white/10 dark:hover:text-white"
                ]}
              >
                {p.label}
              </.link>
            </nav>

            <span
              class="ml-2 truncate font-mono text-xs text-slate-400 dark:text-slate-500"
              title="Working directory — change with /cd <path>"
            >
              {@cwd}
            </span>
          </div>

          <div class="flex flex-none items-center gap-1.5">
            {render_slot_components(:header_extra, assigns)}
            <button
              class={provider_button_class(@provider == :demo)}
              phx-click="set_provider"
              phx-value-provider="demo"
              type="button"
            >
              Demo
            </button>

            <%= if @logged_in do %>
              <button
                class={provider_button_class(@provider == :codex)}
                phx-click="set_provider"
                phx-value-provider="codex"
                type="button"
              >
                Codex ✓
              </button>
              <button
                class="rounded-full p-2 text-slate-500 transition hover:bg-slate-100 hover:text-slate-950 dark:text-slate-300 dark:hover:bg-white/10 dark:hover:text-white"
                phx-click="logout"
                title="Sign out of ChatGPT"
                type="button"
              >
                <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
              </button>
            <% else %>
              <button
                :if={@login_state != :pending}
                class="rounded-full bg-indigo-600 px-3 py-1.5 text-xs font-semibold text-white shadow-sm shadow-indigo-900/20 transition hover:bg-indigo-500"
                phx-click="login"
                type="button"
              >
                Sign in to ChatGPT
              </button>
              <span
                :if={@login_state == :pending}
                class="flex items-center gap-2 text-xs text-slate-500 dark:text-slate-300"
              >
                <span class="size-3 animate-spin rounded-full border-2 border-slate-300 border-t-indigo-500 dark:border-white/20 dark:border-t-indigo-300">
                </span>
                finish in your browser…
              </span>
            <% end %>

            <button
              class="rounded-full px-3 py-1.5 text-xs font-medium text-slate-500 transition hover:bg-slate-100 hover:text-slate-950 dark:text-slate-300 dark:hover:bg-white/10 dark:hover:text-white"
              phx-click="new_session"
              type="button"
            >
              New
            </button>
          </div>
        </header>

        <div
          :if={@boot_status != :ok}
          class="border-b border-amber-300/60 bg-amber-50 px-4 py-2 text-xs text-amber-900 dark:border-amber-400/30 dark:bg-amber-500/10 dark:text-amber-200"
        >
          ⚠ Extensions were not loaded — {boot_status_reason(@boot_status)}. Fix the files in
          ~/.catalyst/extensions (or remove the offender), then ask the agent to run <code class="font-mono">reload_extensions</code>.
        </div>

        {render_active_page(assigns)}
      </div>
    </Layouts.app>
    """
  end

  defp boot_status_reason({:safe_mode, :env}), do: "CATALYST_SAFE_MODE is set"

  defp boot_status_reason({:safe_mode, :crash_detected}),
    do: "the previous boot crashed while extensions were active"

  defp boot_status_reason(_), do: "safe mode"

  defp provider_button_class(active?) do
    [
      "rounded-full px-3 py-1.5 text-xs font-medium transition",
      active? &&
        "bg-slate-950 text-white shadow-sm shadow-slate-950/20 dark:bg-white dark:text-slate-950",
      !active? &&
        "text-slate-500 hover:bg-slate-100 hover:text-slate-950 dark:text-slate-300 dark:hover:bg-white/10 dark:hover:text-white"
    ]
  end

  # Render the active page from the registry (falling back to chat). A broken
  # extension page must not crash-loop the LiveView — recovery (asking the
  # agent to reload_extensions) needs the very chat UI it would take down.
  defp render_active_page(assigns) do
    {mod, fun} =
      case UI.Registry.fetch_page(assigns.page) do
        {:ok, target} -> target
        :error -> {CatalystWeb.Pages.ChatPage, :render}
      end

    try do
      apply(mod, fun, [assigns])
    rescue
      e ->
        Logger.warning(
          "[ui] page #{inspect(mod)}.#{fun} raised: #{Exception.message(e)} — falling back to chat"
        )

        CatalystWeb.Pages.ChatPage.render(assigns)
    catch
      kind, reason ->
        Logger.warning("[ui] page #{inspect(mod)}.#{fun} #{kind}: #{inspect(reason)}")
        CatalystWeb.Pages.ChatPage.render(assigns)
    end
  end

  # Render every component registered for a named slot.
  defp render_slot_components(slot, assigns) do
    assigns = assign(assigns, :__slot_funs__, UI.Registry.components(slot))

    ~H"""
    <%= for fun <- @__slot_funs__ do %>
      {safe_component(fun, assigns)}
    <% end %>
    """
  end

  # A broken extension slot component renders as nothing rather than crashing
  # the whole shell on every render.
  defp safe_component(fun, assigns) do
    fun.(assigns)
  rescue
    e ->
      Logger.warning("[ui] slot component raised: #{Exception.message(e)}")
      nil
  catch
    kind, reason ->
      Logger.warning("[ui] slot component #{kind}: #{inspect(reason)}")
      nil
  end
end
