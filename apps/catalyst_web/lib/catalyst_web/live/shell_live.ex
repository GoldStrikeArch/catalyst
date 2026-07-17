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
  alias Catalyst.Extensions
  alias Catalyst.Extensions.Versioning
  alias Catalyst.LLM.OpenAICodex
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
        chat_form: chat_form(""),
        logged_in: Catalyst.Auth.logged_in?(),
        login_state: :idle,
        login_ref: nil,
        boot_status: Catalyst.Extensions.boot_status(),
        # Extensions panel: data snapshot (built on navigation/action, see
        # maybe_refresh_panel) and the in-flight panel action task, if any.
        ext_panel: nil,
        ext_action: nil,
        # Codex run settings (model/effort/fast/transport) — survive remounts
        # via persistent_term, applied to the session via Server.configure.
        codex_prefs: load_codex_prefs(),
        session_model: nil,
        session_opts: [],
        # "@" file references: the active search (trailing @query in the input)
        # and the label -> path map expanded into the prompt on send.
        file_search: nil,
        file_refs: %{},
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
  def handle_params(params, _uri, socket) do
    page = Map.get(params, "page", "chat")
    {:noreply, socket |> change_page(page) |> maybe_refresh_panel()}
  end

  # Patching back to chat re-renders the message-stream container empty:
  # stream items live only in the DOM, and the other page replaced that DOM.
  # Replay the transcript from the session snapshot (same dedup window as a
  # reattach, so an event broadcast mid-replay isn't doubled).
  defp change_page(%{assigns: %{page: old, session_pid: pid}} = socket, "chat")
       when old != "chat" and is_pid(pid) do
    socket = assign(socket, page: "chat")

    try do
      replay_transcript(socket, pid)
    catch
      # The session died between events — the :DOWN handler reattaches.
      :exit, _reason -> socket
    end
  end

  defp change_page(socket, page), do: assign(socket, page: page)

  # The extensions panel renders a data snapshot, not live registry reads:
  # rebuild it when navigating to the page, after a panel action, and when a
  # run ends (the agent may have installed/removed extensions mid-run).
  defp maybe_refresh_panel(%{assigns: %{page: "extensions"}} = socket) do
    assign(socket,
      ext_panel: CatalystWeb.Pages.ExtensionsPage.panel_data(),
      boot_status: Catalyst.Extensions.boot_status()
    )
  end

  defp maybe_refresh_panel(socket), do: socket

  # No terminate/2 session cleanup: the session outlives the LiveView so a
  # reconnect, page refresh, or self-triggered reload (reload_ui/rebuild_assets)
  # reattaches instead of killing the conversation — including an in-flight run.
  # Sessions are stopped explicitly when a new one replaces them (start_session).

  # ---- events ---------------------------------------------------------------

  @impl true
  def handle_event("typing", %{"message" => text}, socket),
    do: {:noreply, socket |> assign_input(text) |> update_file_search(text)}

  # Enter while the "@" dropdown is showing picks the FIRST match instead of
  # sending — the trailing @query is still a search, not part of the prompt.
  def handle_event(
        "send",
        %{"message" => text},
        %{assigns: %{file_search: %{results: [first | _rest]}}} = socket
      ) do
    {:noreply, pick_file(socket, text, first.label, first.path)}
  end

  def handle_event("send", %{"message" => text}, socket) do
    text = socket.assigns.file_refs |> expand_file_refs(String.trim(text)) |> String.trim()

    cond do
      text == "" or socket.assigns.running ->
        {:noreply, socket}

      # Sessionless shell (start_session failed at mount) — no pid to prompt.
      is_nil(socket.assigns.session_pid) ->
        {:noreply, put_flash(socket, :error, "No active session — click New to start one.")}

      # "/name [arg]" dispatches through the commands registry (built-ins like
      # /cd are seeded there; extensions add their own via register_command).
      # Text merely starting with "/" (e.g. "/etc/passwd holds…") stays a prompt.
      match?({:ok, _name, _arg}, parse_command(text)) ->
        {:ok, name, arg} = parse_command(text)
        {:noreply, run_command(name, arg, socket)}

      true ->
        try do
          case Server.prompt(socket.assigns.session_pid, text) do
            :ok ->
              {:noreply, socket |> assign_input("") |> assign(running: true, file_search: nil)}

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

  def handle_event("pick_file", %{"label" => label, "path" => path}, socket) do
    text = socket.assigns.chat_form.params["message"] || ""
    {:noreply, pick_file(socket, text, label, path)}
  end

  def handle_event("abort", _params, socket) do
    if socket.assigns.session_pid, do: Server.abort(socket.assigns.session_pid)
    {:noreply, socket}
  end

  def handle_event("new_session", _params, socket),
    do: {:noreply, start_session(socket)}

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
    {:noreply, assign(socket, logged_in: false) |> put_flash(:info, "Signed out.")}
  end

  # ---- Codex run settings (model / reasoning effort / fast / transport) ------

  def handle_event("codex_opts", params, socket) do
    prefs =
      socket.assigns.codex_prefs
      |> put_pref(:model, params["model"])
      |> put_pref(:effort, params["effort"])
      |> put_pref(:transport, params["transport"])
      |> clamp_fast()

    {:noreply, apply_codex_prefs(socket, prefs)}
  end

  def handle_event("codex_fast", _params, socket) do
    prefs = clamp_fast(%{socket.assigns.codex_prefs | fast: not socket.assigns.codex_prefs.fast})
    {:noreply, apply_codex_prefs(socket, prefs)}
  end

  # ---- extensions panel actions ----------------------------------------------

  # One panel action at a time: compiles/git can take seconds, and the buttons
  # are disabled while @ext_action is set — this clause catches stragglers.
  def handle_event("ext_" <> _action, _params, %{assigns: %{ext_action: %{}}} = socket),
    do: {:noreply, socket}

  def handle_event("ext_reload_all", _params, socket),
    do: {:noreply, run_ext_action(socket, "reloading all extensions", &reload_all_extensions/0)}

  def handle_event("ext_rollback_last", _params, socket),
    do: {:noreply, run_ext_action(socket, "rolling back", fn -> rollback_extension(nil) end)}

  def handle_event("ext_reload", %{"owner" => owner}, socket),
    do:
      {:noreply, run_ext_action(socket, "reloading #{owner}", fn -> reload_extension(owner) end)}

  def handle_event("ext_rollback", %{"owner" => owner}, socket),
    do:
      {:noreply,
       run_ext_action(socket, "rolling back #{owner}", fn -> rollback_extension(owner) end)}

  def handle_event("ext_disable", %{"owner" => owner}, socket),
    do:
      {:noreply, run_ext_action(socket, "disabling #{owner}", fn -> disable_extension(owner) end)}

  def handle_event("ext_enable", %{"owner" => owner}, socket),
    do: {:noreply, run_ext_action(socket, "enabling #{owner}", fn -> enable_extension(owner) end)}

  # ---- info -----------------------------------------------------------------

  # Agent events arrive tagged with the broadcasting session's id (see
  # Session.Server.broadcast/2). Only events for the session this view is
  # attached to are applied; a mismatched id — e.g. a straggler from a previous
  # session still queued in the mailbox during a switch — is silently dropped,
  # so cross-session leakage is excluded by construction.
  @impl true
  def handle_info({:agent_event, id, event}, socket) do
    if id == socket.assigns.session_id do
      {:noreply, apply_event(event, socket)}
    else
      {:noreply, socket}
    end
  end

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
        # No session restart: the loop pulls a fresh token each turn, so the
        # conversation continues right where it was.
        {:noreply,
         socket
         |> assign(logged_in: true, login_state: :idle, login_ref: nil)
         |> put_flash(:info, "Signed in to ChatGPT.")}

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

  # Extensions-panel action finished — flash the outcome and rebuild the panel
  # snapshot (and the boot-status banner: a successful reload clears safe mode).
  def handle_info({ref, result}, %{assigns: %{ext_action: %{ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])
    socket = socket |> assign(ext_action: nil) |> maybe_refresh_panel()

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
     |> maybe_refresh_panel()
     |> put_flash(:error, "Extension action crashed: #{inspect(reason)}")}
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

  defp assign_input(socket, text), do: assign(socket, chat_form: chat_form(text))

  # `streaming` is nil (no open bubble) or a seed map %{thinking, text} — the
  # content rendered INTO the bubble on its first paint. Subsequent deltas are
  # push_event'd and appended client-side (the bubble is phx-update="ignore",
  # so LiveView never repaints over the appended text). A stale MessageStart
  # replayed around a reattach must not blank an already-seeded bubble.
  defp apply_event(%Event.MessageStart{message: %Message.Assistant{}}, socket),
    do: assign(socket, streaming: socket.assigns.streaming || empty_stream_seed())

  defp apply_event(
         %Event.MessageUpdate{llm_event: %Catalyst.LLM.Event.TextDelta{delta: delta}},
         socket
       ),
       do: socket |> ensure_streaming() |> push_stream_delta("text", delta)

  defp apply_event(
         %Event.MessageUpdate{llm_event: %Catalyst.LLM.Event.ThinkingDelta{delta: delta}},
         socket
       ),
       do: socket |> ensure_streaming() |> push_stream_delta("thinking", delta)

  defp apply_event(%Event.MessageEnd{message: message}, socket) do
    # A MessageEnd broadcast between reattach's subscribe and snapshot call
    # arrives again here; duplicates form an in-order suffix of the replayed
    # snapshot tail. Drop them; the first genuinely new message ends the window.
    # Only this session's own replays can reach the dedup: events are
    # session-tagged and mismatches are dropped in handle_info, so the window
    # never has to consider another session's messages.
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

  # Live partial output (bash streams a throttled tail via ctx.report) shown
  # under the tool spinner. Updates for unknown call ids (already ended, or
  # started before a reattach) are dropped.
  defp apply_event(%Event.ToolExecutionUpdate{call_id: id, partial: partial}, socket) do
    case socket.assigns.tools do
      %{^id => info} = tools ->
        assign(socket, tools: Map.put(tools, id, Map.put(info, :partial, partial_text(partial))))

      _unknown ->
        socket
    end
  end

  defp apply_event(%Event.ToolExecutionEnd{call_id: id}, socket),
    do: assign(socket, tools: Map.delete(socket.assigns.tools, id))

  # Runs can start outside this LiveView (a second window, the CLI, a tool
  # calling Server.continue) — mirror the AgentEnd handling so the running
  # flag, spinner, and Stop button track those runs too.
  defp apply_event(%Event.AgentStart{}, socket),
    do: assign(socket, running: true)

  # Also clear tool spinners: an aborted/failed run never emits
  # ToolExecutionEnd for its pending calls. The run may have installed or
  # removed extensions, so a visible panel snapshot is rebuilt too.
  defp apply_event(%Event.AgentEnd{}, socket),
    do: socket |> assign(running: false, streaming: nil, tools: %{}) |> maybe_refresh_panel()

  defp apply_event(_event, socket), do: socket

  # A delta with no open bubble (e.g. reattached mid-stream) opens one.
  defp ensure_streaming(socket) do
    if socket.assigns.streaming,
      do: socket,
      else: assign(socket, streaming: empty_stream_seed())
  end

  defp empty_stream_seed, do: %{thinking: "", text: ""}

  defp partial_text(%{output: out}) when is_binary(out), do: out
  defp partial_text(out) when is_binary(out), do: out
  defp partial_text(_other), do: nil

  defp push_stream_delta(socket, kind, delta),
    do: push_event(socket, "stream_delta", %{kind: kind, delta: delta})

  defp split_replayed([], _hash), do: :new

  defp split_replayed(tail, hash) do
    case Enum.split_while(tail, &(&1 != hash)) do
      {_skipped, [^hash | rest]} -> {:duplicate, rest}
      _ -> :new
    end
  end

  # ---- extensions panel actions (run inside a supervised task) ---------------

  # Panel actions compile code and shell out to git — seconds, not millis. Run
  # them off the LiveView (like login); the result lands in handle_info and the
  # buttons stay disabled via @ext_action meanwhile.
  defp run_ext_action(socket, label, fun) do
    task = Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, fun)
    assign(socket, ext_action: %{ref: task.ref, label: label})
  end

  defp reload_all_extensions do
    {:ok, %{loaded: loaded, failed: failed}} = Extensions.load_all()

    case failed do
      [] ->
        {:ok, "Reloaded #{length(loaded)} extension file(s)."}

      failed ->
        {:error,
         "Reloaded #{length(loaded)} file(s); #{length(failed)} failed — " <>
           failure_lines(failed)}
    end
  end

  defp reload_extension(owner) do
    case Extensions.reload(owner) do
      {:ok, summary} ->
        {:ok, "Reloaded #{owner}" <> summary_suffix(summary)}

      {:error, reason} ->
        {:error, "Reload of #{owner} failed: " <> Extensions.format_error(reason)}
    end
  end

  defp disable_extension(owner) do
    case Extensions.disable(owner) do
      {:ok, _path} ->
        {:ok, "Disabled #{owner} — its file is kept (.ex.disabled) and skipped at boot."}

      {:error, reason} ->
        {:error, "Disable of #{owner} failed: " <> Extensions.format_error(reason)}
    end
  end

  defp enable_extension(owner) do
    case Extensions.enable(owner) do
      {:ok, summary} ->
        {:ok, "Enabled #{owner}" <> summary_suffix(summary)}

      {:error, reason} ->
        {:error, "Enable of #{owner} failed: " <> Extensions.format_error(reason)}
    end
  end

  # nil = global: undo the newest non-reverted change across all extensions.
  defp rollback_extension(nil) do
    Extensions.dir()
    |> Versioning.rollback()
    |> rollback_result("the most recent extension change")
  end

  defp rollback_extension(owner) do
    case Extensions.source_file(owner) do
      {:ok, path} ->
        Extensions.dir()
        |> Versioning.rollback_file(path)
        |> rollback_result("#{owner}'s most recent change")

      :error ->
        {:error, "Rollback failed: no source file found for #{owner}."}
    end
  end

  defp rollback_result(:ok, what) do
    {:ok, %{loaded: loaded, failed: failed}} = Extensions.load_all()

    case failed do
      [] ->
        {:ok, "Rolled back #{what} and reloaded #{length(loaded)} file(s)."}

      failed ->
        {:error,
         "Rolled back #{what}, but #{length(failed)} file(s) failed to load — " <>
           failure_lines(failed)}
    end
  end

  defp rollback_result({:error, :nothing_to_rollback}, what),
    do: {:error, "Nothing to roll back for #{what} — recent changes were all reverted already."}

  defp rollback_result({:error, reason}, what),
    do: {:error, "Rollback of #{what} failed: #{inspect(reason)}"}

  defp summary_suffix(summary) do
    tools =
      case summary.tools do
        [] -> "."
        tools -> " — tools: #{Enum.join(tools, ", ")}."
      end

    case summary[:warning] do
      nil -> tools
      warning -> tools <> " Warning: #{warning}"
    end
  end

  defp failure_lines(failed) do
    Enum.map_join(failed, "; ", fn {path, reason} ->
      "#{Path.basename(path)}: #{Extensions.format_error(reason)}"
    end)
  end

  # ---- session lifecycle ----------------------------------------------------

  # The most recent session for this (single-user) app instance. A remounting
  # LiveView — reconnect, refresh, or a self-triggered UI reload — reattaches to
  # it instead of starting over.
  @session_ptr {__MODULE__, :current_session}

  defp remember_session(id), do: :persistent_term.put(@session_ptr, %{id: id})

  defp remembered_session do
    if Application.get_env(:catalyst_web, :reattach_sessions, true) do
      :persistent_term.get(@session_ptr, nil)
    end
  end

  defp attach_or_start(socket) do
    case remembered_session() do
      %{id: id} ->
        case await_session(id) do
          pid when is_pid(pid) ->
            reattach_session(socket, id, pid)

          nil ->
            # Stop the abandoned id: a crashed session's supervisor restart
            # could still re-register it after we've moved on, and nothing
            # would ever attach to (or stop) it again.
            Manager.stop(id)
            start_session(socket)
        end

      _none ->
        start_session(socket)
    end
  end

  # A crashed session is restarted by its supervisor under the same id, but the
  # :DOWN handler usually runs before the restart re-registers — poll briefly so
  # recovery reattaches to the restarted session (same transcript) instead of
  # abandoning it and silently starting over.
  defp await_session(id, retries \\ 5)
  defp await_session(id, 0), do: Manager.whereis(id)

  defp await_session(id, retries) do
    case Manager.whereis(id) do
      nil ->
        Process.sleep(20)
        await_session(id, retries - 1)

      pid ->
        pid
    end
  end

  # Rebuild the UI from the live server's snapshot: replay the transcript into
  # the stream and pick up an in-flight run (its events keep arriving via PubSub).
  # Subscribe BEFORE snapshotting so no event can fall in between: anything
  # broadcast before the snapshot answered arrives again via PubSub and is
  # dropped by the replayed_tail dedup (see the MessageEnd apply_event clause).
  # The dedup only ever sees this session's events — broadcasts carry the
  # session id and handle_info drops mismatches, so a switch can't leak another
  # session's messages into the replay window.
  defp reattach_session(socket, id, pid) do
    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    socket
    |> monitor_session(pid)
    |> assign(session_id: id, session_pid: pid)
    |> replay_transcript(pid)
    |> sync_codex_ui()
  catch
    # The server died between whereis and the state call (GenServer.call
    # exits) — start fresh. ONLY :exit: an :error here is a real bug in the
    # replay code and must crash visibly, not masquerade as transcript loss.
    :exit, _reason ->
      Phoenix.PubSub.unsubscribe(Catalyst.PubSub, Server.topic(id))
      start_session(socket)
  end

  # Rebuild the message stream (and run-tracking assigns) from the session's
  # snapshot — used on reattach and when patching back to the chat page (whose
  # stream items live only in DOM the other page replaced). Callers handle a
  # dead pid (`Server.state/1` exits).
  defp replay_transcript(socket, pid) do
    snapshot = Server.state(pid)
    flush_stale_deltas(snapshot.id)

    {socket, seq} =
      Enum.reduce(snapshot.messages, {stream(socket, :messages, [], reset: true), 0}, fn
        msg, {sock, seq} -> {stream_insert(sock, :messages, %{id: seq + 1, msg: msg}), seq + 1}
      end)

    socket
    |> assign(
      cwd: snapshot.cwd,
      running: snapshot.running,
      streaming: nil,
      tools: %{},
      message_seq: seq,
      message_count: seq,
      session_model: snapshot.model,
      session_opts: snapshot[:opts] || [],
      replayed_tail: snapshot.messages |> Enum.take(-10) |> Enum.map(&:erlang.phash2/1)
    )
    |> seed_streaming(snapshot.streaming_message)
  end

  # Rebuild the in-flight bubble from the snapshot's accumulated partial
  # content — a late joiner (reattach, page return) sees the text streamed so
  # far, and deltas arriving after the snapshot append client-side on top.
  defp seed_streaming(socket, %Message.Assistant{content: content}) do
    seed = %{
      thinking:
        content
        |> Enum.filter(&match?(%Catalyst.Content.Thinking{}, &1))
        |> Enum.map_join("", & &1.thinking),
      text:
        content
        |> Enum.filter(&match?(%Catalyst.Content.Text{}, &1))
        |> Enum.map_join("", & &1.text)
    }

    assign(socket, streaming: seed)
  end

  defp seed_streaming(socket, _none), do: socket

  # After `Server.state/1` returns, every MessageUpdate already in our mailbox
  # is ≤ the snapshot (the session server both dispatches the PubSub sends and
  # answers the call, and per-pair message order is guaranteed) — appending
  # those deltas onto the seeded bubble would duplicate text. Anything arriving
  # after this flush is genuinely newer than the snapshot.
  defp flush_stale_deltas(id) do
    receive do
      {:agent_event, ^id, %Event.MessageUpdate{}} -> flush_stale_deltas(id)
    after
      0 -> :ok
    end
  end

  defp start_session(socket) do
    if old_id = socket.assigns.session_id do
      # Unsubscribe doesn't flush the mailbox, but any already-delivered event
      # from the old session carries old_id and is dropped by the handle_info
      # session-id check once the new id is assigned below.
      Phoenix.PubSub.unsubscribe(Catalyst.PubSub, Server.topic(old_id))
      Manager.stop(old_id)
    end

    {provider_mod, model} = provider_config(socket)
    run_opts = codex_run_opts(socket.assigns.codex_prefs)

    case Manager.start_session(
           cwd: socket.assigns.cwd,
           provider: provider_mod,
           model: model,
           opts: run_opts
         ) do
      {:ok, %{id: id, pid: pid}} ->
        Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))
        remember_session(id)

        socket
        |> monitor_session(pid)
        |> assign(
          session_id: id,
          session_pid: pid,
          session_model: model,
          session_opts: run_opts,
          streaming: nil,
          running: false,
          tools: %{},
          message_seq: 0,
          message_count: 0,
          replayed_tail: [],
          file_search: nil,
          file_refs: %{},
          chat_form: chat_form("")
        )
        |> stream(:messages, [], reset: true)

      # Session init does filesystem work (store dir, transcript load), so it
      # can fail. This runs from mount via attach_or_start — crashing here
      # would crash-loop the LiveView on every rejoin with no UI at all, so
      # degrade to a sessionless shell and explain.
      {:error, reason} ->
        Logger.error("[shell] could not start a session: #{inspect(reason)}")
        if ref = socket.assigns.session_ref, do: Process.demonitor(ref, [:flush])

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
  end

  # One monitor per attached session: the :DOWN handler reattaches gracefully
  # when the session is stopped from elsewhere (another window) or crashes.
  defp monitor_session(socket, pid) do
    if ref = socket.assigns.session_ref, do: Process.demonitor(ref, [:flush])
    assign(socket, session_ref: Process.monitor(pid))
  end

  defp provider_config(socket) do
    {provider_mod(), OpenAICodex.model(socket.assigns.codex_prefs.model)}
  end

  # Injectable so tests can drive full turns with an offline provider.
  defp provider_mod do
    Application.get_env(:catalyst_web, :codex_provider_mod, Catalyst.LLM.OpenAICodex.Provider)
  end

  # ---- Codex run settings helpers ---------------------------------------------

  @codex_prefs_ptr {__MODULE__, :codex_prefs}

  defp load_codex_prefs do
    default = %{
      model: OpenAICodex.default_model_id(),
      effort: OpenAICodex.default_effort(),
      fast: false,
      transport: "auto"
    }

    case :persistent_term.get(@codex_prefs_ptr, nil) do
      %{} = saved -> Map.merge(default, saved)
      _none -> default
    end
  end

  defp save_codex_prefs(prefs), do: :persistent_term.put(@codex_prefs_ptr, prefs)

  defp put_pref(prefs, _key, nil), do: prefs
  defp put_pref(prefs, key, value), do: Map.put(prefs, key, value)

  # Fast (the "priority" service tier) only exists on models that support it.
  defp clamp_fast(prefs) do
    case OpenAICodex.catalog_entry(prefs.model).fast? do
      true -> prefs
      false -> %{prefs | fast: false}
    end
  end

  # nil values matter: Server.configure's merge DELETES nil keys, so turning
  # Fast off actually removes service_tier from the session opts.
  defp codex_run_opts(prefs) do
    [
      reasoning_effort: prefs.effort,
      service_tier: if(prefs.fast, do: "priority"),
      transport: prefs.transport
    ]
  end

  # Persist + apply the settings. With a live Codex session they reconfigure
  # it for the NEXT run — no session restart, the transcript stays.
  defp apply_codex_prefs(socket, prefs) do
    save_codex_prefs(prefs)
    socket = assign(socket, codex_prefs: prefs)

    case socket.assigns do
      %{session_pid: pid} when is_pid(pid) ->
        model = OpenAICodex.model(prefs.model)
        opts = codex_run_opts(prefs)

        try do
          :ok = Server.configure(pid, model: model, opts: opts)
          assign(socket, session_model: model, session_opts: opts)
        catch
          # Session died mid-click — the :DOWN handler reattaches; prefs are
          # saved and re-applied when the next session starts.
          :exit, _reason -> socket
        end

      _no_session ->
        socket
    end
  end

  # After a reattach the SESSION is the source of truth for the controls.
  defp sync_codex_ui(socket) do
    model = socket.assigns.session_model || OpenAICodex.model(socket.assigns.codex_prefs.model)
    opts = socket.assigns.session_opts || []

    prefs =
      clamp_fast(%{
        model: model.id,
        effort: opts[:reasoning_effort] || OpenAICodex.default_effort(),
        fast: opts[:service_tier] == "priority",
        transport: to_string(opts[:transport] || "auto")
      })

    save_codex_prefs(prefs)
    assign(socket, codex_prefs: prefs)
  end

  # ---- "@" file references ------------------------------------------------------

  # A trailing "@token" (preceded by whitespace or start-of-input) is an active
  # file search; an "@" inside a word (a@b) is not.
  defp active_file_query(text) do
    case Regex.run(~r/(?:^|\s)@(\S*)$/, text) do
      [_, query] -> query
      _no_match -> nil
    end
  end

  defp update_file_search(socket, text) do
    case active_file_query(text) do
      nil ->
        assign(socket, file_search: nil)

      query ->
        results = CatalystWeb.FileSearch.search(socket.assigns.cwd, query)
        assign(socket, file_search: %{query: query, results: results})
    end
  end

  # Replace the trailing @query with the picked label and remember the
  # label -> path mapping for expansion at send time.
  defp pick_file(socket, text, label, path) do
    new_text = Regex.replace(~r/@\S*$/, text, fn _match -> label <> " " end)

    socket
    |> assign_input(new_text)
    |> assign(
      file_search: nil,
      file_refs: Map.put(socket.assigns.file_refs, label, path)
    )
  end

  # Expand picked "@parent/name" labels into real (cwd-relative) paths for the
  # model. Longest labels first so a label can't clobber a longer one that
  # contains it.
  defp expand_file_refs(refs, text) when refs == %{}, do: text

  defp expand_file_refs(refs, text) do
    refs
    |> Enum.sort_by(fn {label, _path} -> -byte_size(label) end)
    |> Enum.reduce(text, fn {label, path}, acc -> String.replace(acc, label, path) end)
  end

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
    expanded = Path.expand(path, socket.assigns.cwd)

    if File.dir?(expanded) do
      socket
      |> assign(cwd: expanded)
      |> assign_input("")
      |> start_session()
    else
      put_flash(socket, :error, "Not a directory: #{expanded}")
    end
  end

  # ---- chat commands --------------------------------------------------------

  @doc "The built-in `/cd` command (seeded into `UI.Registry` at boot)."
  def command_cd("", socket), do: put_flash(socket, :error, "usage: /cd <path>")
  def command_cd(path, socket), do: set_cwd(socket, path)

  # "/name" or "/name arg…" where name is a bare word — anything else (like a
  # unix path) is not a command attempt and falls through to the model.
  defp parse_command(text) do
    case Regex.run(~r/^\/([a-z0-9_-]+)(?:\s+(.*))?$/s, text) do
      [_, name] -> {:ok, name, ""}
      [_, name, arg] -> {:ok, name, String.trim(arg)}
      nil -> :error
    end
  end

  # Handlers are `fun(arg, socket) -> socket` and crash-isolated: a broken
  # extension command flashes an error instead of taking down the LiveView.
  defp run_command(name, arg, socket) do
    case UI.Registry.fetch_command(name) do
      {:ok, %{handler: handler}} when is_function(handler, 2) ->
        safe_command(handler, arg, socket)

      {:ok, _entry_without_handler} ->
        put_flash(socket, :error, "command /#{name} has no handler")

      :error ->
        known =
          UI.Registry.list_commands()
          |> Enum.map(&("/" <> &1.name))
          |> Enum.sort()
          |> Enum.join(", ")

        put_flash(socket, :error, "unknown command /#{name} (known: #{known})")
    end
  end

  defp safe_command(handler, arg, socket) do
    %Phoenix.LiveView.Socket{} = handler.(arg, socket)
  rescue
    e -> put_flash(socket, :error, "command failed: #{Exception.message(e)}")
  catch
    kind, reason -> put_flash(socket, :error, "command failed: #{kind} #{inspect(reason)}")
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
            <span :if={@running} class="flex items-center gap-1" aria-label="Agent running">
              <span class="size-1.5 animate-pulse rounded-full bg-indigo-500"></span>
              <span class="size-1.5 animate-pulse rounded-full bg-indigo-500 delay-150"></span>
              <span class="size-1.5 animate-pulse rounded-full bg-indigo-500 delay-300"></span>
            </span>

            <nav :if={length(UI.Registry.list_pages()) > 1} class="flex items-center gap-1">
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

            <%!-- Codex run settings: applied to the live session for the NEXT
            run (Server.configure) — no session restart, transcript stays. --%>
            <div class="flex items-center gap-1.5">
              <form id="codex-opts" phx-change="codex_opts" class="flex items-center gap-1.5">
                <select name="model" class={codex_select_class()} title="Codex model">
                  <option
                    :for={m <- OpenAICodex.list_models()}
                    value={m.id}
                    selected={m.id == @codex_prefs.model}
                  >
                    {m.name}
                  </option>
                </select>
                <select name="effort" class={codex_select_class()} title="Reasoning effort">
                  <option
                    :for={e <- OpenAICodex.catalog_entry(@codex_prefs.model).efforts}
                    value={e}
                    selected={e == @codex_prefs.effort}
                  >
                    {e}
                  </option>
                </select>
                <select
                  name="transport"
                  class={codex_select_class()}
                  title="Transport: auto = websocket with SSE fallback"
                >
                  <option
                    :for={{v, l} <- [{"auto", "auto"}, {"websocket", "ws"}, {"sse", "sse"}]}
                    value={v}
                    selected={v == @codex_prefs.transport}
                  >
                    {l}
                  </option>
                </select>
              </form>
              <button
                :if={OpenAICodex.catalog_entry(@codex_prefs.model).fast?}
                type="button"
                phx-click="codex_fast"
                title="Fast mode (priority service tier): ~1.5x speed, increased usage"
                class={fast_button_class(@codex_prefs.fast)}
              >
                ⚡ Fast
              </button>
            </div>

            <%= if @logged_in do %>
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
          ⚠ Extensions were not loaded — {boot_status_reason(@boot_status)}. Recover from the
          <.link patch={~p"/extensions"} class="font-semibold underline">Extensions panel</.link>
          (disable or roll back the offender, then load again), or ask the agent to run <code class="font-mono">reload_extensions</code>.
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

  defp codex_select_class do
    "rounded-full border border-slate-200 bg-white/70 px-2 py-1 text-xs font-medium " <>
      "text-slate-600 outline-none transition focus:border-indigo-400 " <>
      "dark:border-white/10 dark:bg-white/10 dark:text-slate-300"
  end

  defp fast_button_class(active?) do
    [
      "rounded-full border px-2.5 py-1 text-xs font-semibold transition",
      active? &&
        "border-amber-400 bg-amber-100 text-amber-900 dark:border-amber-400/40 dark:bg-amber-400/20 dark:text-amber-200",
      !active? &&
        "border-slate-200 text-slate-500 hover:bg-slate-100 dark:border-white/10 dark:text-slate-300 dark:hover:bg-white/10"
    ]
  end

  # Render the active page from the registry (falling back to chat). A broken
  # extension page must not crash-loop the LiveView — recovery (asking the
  # agent to reload_extensions) needs the very chat UI it would take down, and
  # the page path persists in the URL, so a remount would just re-render it.
  #
  # Calling a ~H page function only BUILDS a %Phoenix.LiveView.Rendered{}; its
  # dynamic closures run later in the diff engine, outside any guard here. So
  # for extension pages the template is forced to iodata INSIDE the guard
  # (raise/throw/exit — e.g. a bad assign or a GenServer call in the template —
  # all fall back to chat). That trades fine-grained diffs for real isolation,
  # on extension content only: the built-in chat page (the app's own compiled
  # code) stays on the normal lazy/diffable path.
  defp render_active_page(assigns) do
    {mod, fun} =
      case UI.Registry.fetch_page(assigns.page) do
        {:ok, target} -> target
        :error -> {CatalystWeb.Pages.ChatPage, :render}
      end

    # The registry's seeded builtin pages are ChatPage and ExtensionsPage
    # (owner: nil), but fetch_page/1 doesn't expose the owner tag — so trust
    # exactly the app's own compiled page modules. That's reliable: extension
    # code can register any path, but it can never BE these compiled modules.
    if mod in [CatalystWeb.Pages.ChatPage, CatalystWeb.Pages.ExtensionsPage] do
      apply(mod, fun, [assigns])
    else
      try do
        rendered = apply(mod, fun, [assigns])
        {:safe, Phoenix.HTML.Safe.to_iodata(rendered)}
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
  # the whole shell on every render. Slot components only ever come from
  # runtime (extension) registration — the registry seeds no builtins here —
  # so every one is forced to iodata inside the guard: calling the ~H fun only
  # builds a lazy Rendered whose dynamics would otherwise run later in the
  # diff engine, outside this rescue. raise/throw/exit all render as nothing.
  defp safe_component(fun, assigns) do
    {:safe, Phoenix.HTML.Safe.to_iodata(fun.(assigns))}
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
