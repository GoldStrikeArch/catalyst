defmodule CatalystWeb.ShellLive do
  @moduledoc """
  The single LiveView for the whole app, mounted at `/` and `/:page`. It owns the
  `Catalyst.Session.Server` (started on connect), subscribes to its
  `"session:<id>"` topic, and renders the shell chrome (title, provider/login,
  page nav) plus the **active page** resolved from `CatalystWeb.UI.Registry`.

  The default page is `"chat"` (`CatalystWeb.Pages.ChatPage`); extensions can
  register additional pages (e.g. `/settings`) at runtime with no router change.
  All page content is rendered through the registry, and conversation messages
  through `CatalystWeb.UI.MessageRenderer`, so the UI is runtime-extensible.
  """
  use CatalystWeb, :live_view

  alias Catalyst.Message
  alias Catalyst.Agent.Event
  alias Catalyst.Session.{Manager, Server}
  alias CatalystWeb.{Assets, UI}

  @system_prompt """
  You are Catalyst, a concise coding agent running on the user's machine.
  You can read files, run shell commands, search with ripgrep, find files with fd,
  edit files, replace text with sd, and make structural edits with ast-grep.
  Prefer using tools to inspect the repository before answering. Keep replies short.

  Self-extension: if you need a capability no built-in tool provides, you can write a
  new tool for yourself by calling `develop_tool` with an Elixir module that
  `use Catalyst.Tools.Tool` and implements name/0, description/0, parameters/0 (a JSON
  Schema object) and execute/2. In execute(args, ctx): resolve paths with
  Catalyst.Tools.Paths.resolve(path, ctx.cwd), return result("text", %{}), and raise on
  failure. Namespace modules under Catalyst.Ext.*. The new tool is loaded immediately and
  callable on your next turn. Only do this when an existing tool can't do the job. For the
  full contract, helpers and examples, read the guide at ~/.catalyst/guide.md.

  Debugging: if a step fails or behaves unexpectedly, call `read_log` to see this session's
  debug log (every agent-loop step, tool call, and truncated LLM request/response and error)
  before deciding what to do next.
  """

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page: "chat",
        messages: [],
        streaming: nil,
        running: false,
        tools: %{},
        input: "",
        logged_in: Catalyst.Auth.logged_in?(),
        login_state: :idle,
        login_ref: nil,
        provider: :demo,
        model_label: "Demo (offline)",
        session_id: nil,
        session_pid: nil,
        cwd: default_cwd()
      )

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Catalyst.PubSub, Assets.topic())
      {:ok, start_session(socket, :demo)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, page: Map.get(params, "page", "chat"))}

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns.session_id, do: Manager.stop(socket.assigns.session_id)
    :ok
  end

  # ---- events ---------------------------------------------------------------

  @impl true
  def handle_event("typing", %{"message" => text}, socket),
    do: {:noreply, assign(socket, input: text)}

  def handle_event("send", %{"message" => text}, socket) do
    text = String.trim(text)

    cond do
      text == "" or socket.assigns.running ->
        {:noreply, socket}

      # `/cd <path>` points the session at a different working directory.
      String.starts_with?(text, "/cd ") ->
        {:noreply, set_cwd(socket, text |> String.replace_prefix("/cd ", "") |> String.trim())}

      true ->
        Server.prompt(socket.assigns.session_pid, text)
        {:noreply, assign(socket, input: "", running: true)}
    end
  end

  def handle_event("abort", _params, socket) do
    if socket.assigns.session_pid, do: Server.abort(socket.assigns.session_pid)
    {:noreply, socket}
  end

  def handle_event("new_session", _params, socket),
    do: {:noreply, start_session(socket, socket.assigns.provider)}


  def handle_event("set_provider", %{"provider" => "codex"}, socket) do
    if socket.assigns.logged_in do
      {:noreply, start_session(socket, :codex)}
    else
      {:noreply, put_flash(socket, :error, "Not signed in. Run `mix catalyst.login` first.")}
    end
  end

  def handle_event("set_provider", %{"provider" => _demo}, socket),
    do: {:noreply, start_session(socket, :demo)}

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

  # An asset rebuild happened — full reload so the new app.js/app.css are fetched.
  def handle_info(:reload_assets, socket), do: {:noreply, redirect(socket, to: "/")}

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

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Overridable so tests can stub the OAuth flow.
  defp login_fun, do: Application.get_env(:catalyst_web, :login_fun, &Catalyst.Auth.login_openai_codex/0)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp apply_event(%Event.MessageStart{message: %Message.Assistant{}}, socket),
    do: assign(socket, streaming: %{text: "", thinking: ""})

  defp apply_event(%Event.MessageUpdate{llm_event: %Catalyst.LLM.Event.TextDelta{delta: d}}, socket),
    do: update_streaming(socket, :text, d)

  defp apply_event(%Event.MessageUpdate{llm_event: %Catalyst.LLM.Event.ThinkingDelta{delta: d}}, socket),
    do: update_streaming(socket, :thinking, d)

  defp apply_event(%Event.MessageEnd{message: message}, socket) do
    streaming = if match?(%Message.Assistant{}, message), do: nil, else: socket.assigns.streaming
    assign(socket, messages: socket.assigns.messages ++ [message], streaming: streaming)
  end

  defp apply_event(%Event.ToolExecutionStart{call_id: id, name: name, args: args}, socket),
    do: assign(socket, tools: Map.put(socket.assigns.tools, id, %{name: name, args: args}))

  defp apply_event(%Event.ToolExecutionEnd{call_id: id}, socket),
    do: assign(socket, tools: Map.delete(socket.assigns.tools, id))

  defp apply_event(%Event.AgentEnd{}, socket),
    do: assign(socket, running: false, streaming: nil)

  defp apply_event(_event, socket), do: socket

  defp update_streaming(socket, key, delta) do
    streaming = socket.assigns.streaming || %{text: "", thinking: ""}
    assign(socket, streaming: Map.update(streaming, key, delta, &(&1 <> delta)))
  end

  # ---- session lifecycle ----------------------------------------------------

  defp start_session(socket, provider) do
    if socket.assigns.session_id, do: Manager.stop(socket.assigns.session_id)

    {provider_mod, model, label} = provider_config(provider)

    {:ok, %{id: id, pid: pid}} =
      Manager.start_session(
        cwd: socket.assigns.cwd,
        provider: provider_mod,
        model: model,
        system_prompt: @system_prompt
      )

    Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))

    assign(socket,
      session_id: id,
      session_pid: pid,
      provider: provider,
      model_label: label,
      messages: [],
      streaming: nil,
      running: false,
      tools: %{}
    )
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
      socket |> assign(cwd: expanded, input: "") |> start_session(socket.assigns.provider)
    else
      put_flash(socket, :error, "Not a directory: #{expanded}")
    end
  end

  # ---- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="flex flex-col h-screen bg-base-200">
      <header class="navbar bg-base-100 border-b border-base-300 px-4 min-h-0 py-2">
        <div class="flex-1 flex items-center gap-2">
          <span class="text-lg font-bold">Catalyst</span>
          <span class="badge badge-sm badge-ghost">{@model_label}</span>
          <span :if={@running} class="loading loading-dots loading-xs text-primary"></span>

          <nav :if={length(UI.Registry.list_pages()) > 1} class="flex items-center gap-1 ml-3">
            <.link
              :for={p <- UI.Registry.list_pages()}
              patch={~p"/#{p.path}"}
              class={["btn btn-xs btn-ghost", @page == p.path && "btn-active"]}
            >
              {p.label}
            </.link>
          </nav>

          <span class="text-xs text-base-content/50 font-mono ml-2 truncate max-w-xs" title="Working directory — change with /cd <path>">
            {@cwd}
          </span>
        </div>
        <div class="flex-none flex items-center gap-1">
          {render_slot_components(:header_extra, assigns)}
          <button
            class={["btn btn-xs", @provider == :demo && "btn-primary"]}
            phx-click="set_provider"
            phx-value-provider="demo"
          >
            Demo
          </button>

          <%= if @logged_in do %>
            <button
              class={["btn btn-xs", @provider == :codex && "btn-primary"]}
              phx-click="set_provider"
              phx-value-provider="codex"
            >
              Codex ✓
            </button>
            <button class="btn btn-xs btn-ghost" phx-click="logout" title="Sign out of ChatGPT">⏏</button>
          <% else %>
            <button :if={@login_state != :pending} class="btn btn-xs btn-secondary" phx-click="login">
              Sign in to ChatGPT
            </button>
            <span :if={@login_state == :pending} class="text-xs flex items-center gap-1">
              <span class="loading loading-spinner loading-xs"></span> finish in your browser…
            </span>
          <% end %>

          <button class="btn btn-xs btn-ghost" phx-click="new_session">New</button>
        </div>
      </header>

      <%= render_active_page(assigns) %>
    </div>
    """
  end

  # Render the active page from the registry (falling back to chat).
  defp render_active_page(assigns) do
    {mod, fun} = UI.Registry.fetch_page(assigns.page) || {CatalystWeb.Pages.ChatPage, :render}
    apply(mod, fun, [assigns])
  end

  # Render every component registered for a named slot.
  defp render_slot_components(slot, assigns) do
    assigns = assign(assigns, :__slot_funs__, UI.Registry.components(slot))

    ~H"""
    <%= for fun <- @__slot_funs__ do %>{fun.(assigns)}<% end %>
    """
  end
end
