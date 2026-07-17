defmodule CatalystWeb.ChatLive do
  @moduledoc """
  The chat UI. Owns a `Catalyst.Session.Server` (started on connect), subscribes
  to its `"session:<id>"` PubSub topic, and renders the conversation live:
  streaming assistant tokens, thinking blocks, tool-call cards, and tool results.
  Offline by default via the Demo provider; switch to Codex once logged in.
  """
  use CatalystWeb, :live_view

  alias Catalyst.{Content, Message}
  alias Catalyst.Agent.Event
  alias Catalyst.Session.{Manager, Server}

  @system_prompt """
  You are Catalyst, a concise coding agent running on the user's machine.
  You can read files, run shell commands, search with ripgrep, find files with fd,
  edit files, replace text with sd, and make structural edits with ast-grep.
  Prefer using tools to inspect the repository before answering. Keep replies short.
  """

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        messages: [],
        streaming: nil,
        running: false,
        tools: %{},
        input: "",
        logged_in: Catalyst.Auth.logged_in?(),
        provider: :demo,
        model_label: "Demo (offline)",
        session_id: nil,
        session_pid: nil,
        cwd: File.cwd!()
      )

    if connected?(socket) do
      {:ok, start_session(socket, :demo)}
    else
      {:ok, socket}
    end
  end

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

    if text == "" or socket.assigns.running do
      {:noreply, socket}
    else
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

  # ---- agent events ---------------------------------------------------------

  @impl true
  def handle_info({:agent_event, event}, socket), do: {:noreply, apply_event(event, socket)}

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
        </div>
        <div class="flex-none flex items-center gap-1">
          <button
            class={["btn btn-xs", @provider == :demo && "btn-primary"]}
            phx-click="set_provider"
            phx-value-provider="demo"
          >
            Demo
          </button>
          <button
            class={["btn btn-xs", @provider == :codex && "btn-primary", !@logged_in && "btn-disabled"]}
            phx-click="set_provider"
            phx-value-provider="codex"
            title={!@logged_in && "Run mix catalyst.login first"}
          >
            Codex {if @logged_in, do: "✓", else: "🔒"}
          </button>
          <button class="btn btn-xs btn-ghost" phx-click="new_session">New</button>
        </div>
      </header>

      <div id="messages" phx-hook="ScrollBottom" class="flex-1 overflow-y-auto px-4 py-6 space-y-2">
        <div :if={@messages == [] and is_nil(@streaming)} class="text-center text-base-content/50 mt-20">
          <p class="text-sm">Ask Catalyst to inspect this project.</p>
          <p class="text-xs mt-1">cwd: {@cwd}</p>
        </div>

        <.message :for={msg <- @messages} msg={msg} />

        <div :if={@streaming} class="chat chat-start">
          <div class="chat-bubble chat-bubble-neutral whitespace-pre-wrap">
            <span :if={@streaming.thinking != ""} class="block text-xs italic opacity-60 mb-1">{@streaming.thinking}</span>{@streaming.text}<span class="animate-pulse">▌</span>
          </div>
        </div>

        <div :for={{_id, t} <- @tools} class="chat chat-start">
          <div class="chat-bubble chat-bubble-info text-sm flex items-center gap-2">
            <span class="loading loading-spinner loading-xs"></span> running <code>{t.name}</code>…
          </div>
        </div>
      </div>

      <form phx-submit="send" phx-change="typing" class="bg-base-100 border-t border-base-300 p-3 flex gap-2">
        <input
          type="text"
          name="message"
          value={@input}
          autocomplete="off"
          placeholder="Ask Catalyst…  (e.g. “list the files” or “search defmodule”)"
          class="input input-bordered flex-1"
        />
        <button :if={!@running} type="submit" class="btn btn-primary">Send</button>
        <button :if={@running} type="button" phx-click="abort" class="btn btn-error">Stop</button>
      </form>
    </div>
    """
  end

  # ---- message components ---------------------------------------------------

  defp message(%{msg: %Message.User{}} = assigns) do
    ~H"""
    <div class="chat chat-end">
      <div class="chat-bubble chat-bubble-primary whitespace-pre-wrap">{Content.text_of(@msg.content)}</div>
    </div>
    """
  end

  defp message(%{msg: %Message.Assistant{}} = assigns) do
    ~H"""
    <div :if={@msg.content != []} class="chat chat-start">
      <div class="chat-bubble chat-bubble-neutral whitespace-pre-wrap">
        <.block :for={b <- @msg.content} block={b} />
      </div>
    </div>
    """
  end

  defp message(%{msg: %Message.ToolResult{}} = assigns) do
    ~H"""
    <div class="px-2">
      <div class={[
        "rounded-lg border text-xs font-mono overflow-hidden",
        @msg.is_error && "border-error/50 bg-error/10",
        !@msg.is_error && "border-base-300 bg-base-100"
      ]}>
        <div class="px-3 py-1 border-b border-base-300/50 font-semibold flex items-center gap-2">
          <span>{@msg.tool_name}</span>
          <span :if={@msg.is_error} class="badge badge-error badge-xs">error</span>
        </div>
        <pre class="px-3 py-2 whitespace-pre-wrap max-h-60 overflow-y-auto">{tool_output(@msg)}</pre>
      </div>
    </div>
    """
  end

  defp block(%{block: %Content.Text{}} = assigns) do
    ~H"{@block.text}"
  end

  defp block(%{block: %Content.Thinking{}} = assigns) do
    ~H"""
    <details class="text-xs italic opacity-60 my-1">
      <summary class="cursor-pointer">thinking</summary>
      <div class="whitespace-pre-wrap mt-1">{@block.thinking}</div>
    </details>
    """
  end

  defp block(%{block: %Content.ToolCall{}} = assigns) do
    ~H"""
    <div class="text-xs opacity-70 my-1">
      <span class="badge badge-xs badge-ghost">tool</span>
      <code>{@block.name}({short_args(@block.arguments)})</code>
    </div>
    """
  end

  defp block(assigns), do: ~H""

  defp tool_output(%Message.ToolResult{content: content}) do
    content
    |> Content.text_of()
    |> String.split("\n")
    |> Enum.take(40)
    |> Enum.join("\n")
  end

  defp short_args(args) when is_map(args) and map_size(args) == 0, do: ""

  defp short_args(args) when is_map(args) do
    args |> Jason.encode!() |> String.slice(0, 80)
  end

  defp short_args(_), do: ""
end
